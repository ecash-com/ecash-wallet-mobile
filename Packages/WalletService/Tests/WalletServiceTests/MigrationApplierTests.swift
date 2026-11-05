// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import Foundation
@testable import WalletService

/// The seed-container migration APPLIER over the mock factory + in-memory store
/// (`docs/seed-container-model.md §6.3`): every move is verified by a reopen + balance check on
/// both sides, a failure backs that one record out and the rest still migrates, the report
/// carries ids only, and nothing runs twice. The real-BDK counterpart is `MigrationApplierBDKTests`.
final class MigrationApplierTests: XCTestCase {

    private static let fp = "d34db33f"

    private func hd(_ id: String, _ network: WalletNetwork, sort: Int, label: String = "Wallet",
                    script: ScriptType = .bip84, backedUp: Bool = false) -> ManagedWallet {
        let coin = network == .signet ? "1" : "0"
        let key = network == .signet ? "tpubDC...\(id)" : "xpub6C...\(id)"
        return ManagedWallet(id: id, label: label, network: network,
                             externalDescriptor: "wpkh([\(Self.fp)/\(script.purpose)'/\(coin)'/0']\(key)/0/*)#aaaaaaaa",
                             internalDescriptor: "wpkh([\(Self.fp)/\(script.purpose)'/\(coin)'/0']\(key)/1/*)#bbbbbbbb",
                             keyType: .mnemonic, scriptType: script, accountIndex: 0,
                             isBackedUp: backedUp, sortIndex: sort)
    }

    private struct Rig {
        let store: InMemoryWalletStore
        let factory: MockWalletEngineFactory
        let applier: WalletMigrationV2Applier
    }

    private func rig(_ legacy: [ManagedWallet], files: [String: Int64]) throws -> Rig {
        let store = InMemoryWalletStore()
        for w in legacy { try store.upsertWallet(w) }
        let factory = MockWalletEngineFactory()
        for (name, balance) in files {
            factory.chainDataFiles.append(name)
            factory.cachedBalances[name] = balance
        }
        return Rig(store: store, factory: factory, applier: WalletMigrationV2Applier(store: store, factory: factory))
    }

    // MARK: - Happy path

    func testMergesACopyMovesItsStoreAndCommitsV2() throws {
        let r = try rig([hd("orig", .ecashMainnet, sort: 0, label: "Main"),
                         hd("copy", .bitcoin, sort: 1, label: "Main (Bitcoin)", backedUp: true)],
                        files: ["orig-ecashMainnet.sqlite": 1_000, "copy-bitcoin.sqlite": 55_000])
        r.factory.chainDataFiles.append("copy-bitcoin.sqlite-wal")

        let report = try XCTUnwrap(try r.applier.migrateIfNeeded(selectedId: "copy", nowEpochSeconds: Int64(1_800_000_000)))

        XCTAssertTrue(r.store.isV2)
        XCTAssertTrue(r.store.migrationBegun)                              // snapshot taken first
        let wallets = try r.store.allWallets()
        XCTAssertEqual(wallets.map { $0.id }, ["orig"])
        XCTAssertEqual(wallets[0].accounts.map { $0.storeName }, ["orig-ecashMainnet.sqlite", "orig-bitcoin-bip84-0.sqlite"])
        XCTAssertEqual(wallets[0].selectedAccountId, "bitcoin-bip84-0")   // selection followed the copy
        XCTAssertTrue(wallets[0].isBackedUp)
        XCTAssertEqual(wallets[0].orphanKeychainIds, ["copy"])

        // The store moved (sidecar along with it) and kept its balance; the original never moved.
        XCTAssertEqual(r.factory.storeMoves, ["copy-bitcoin.sqlite>orig-bitcoin-bip84-0.sqlite"])
        XCTAssertEqual(Set(r.factory.chainDataFiles),
                       ["orig-ecashMainnet.sqlite", "orig-bitcoin-bip84-0.sqlite", "orig-bitcoin-bip84-0.sqlite-wal"])
        XCTAssertEqual(r.factory.cachedBalances["orig-bitcoin-bip84-0.sqlite"], 55_000)

        XCTAssertEqual(report.selectedWalletId, "orig")
        XCTAssertEqual(report.walletId(forLegacy: "copy"), "orig")
        XCTAssertEqual(report.walletId(forLegacy: "orig"), "orig")
        XCTAssertNil(report.walletId(forLegacy: "gone"))
        XCTAssertTrue(report.excluded.isEmpty)
        XCTAssertEqual(report.appliedAtEpochSeconds, Int64(1_800_000_000))
        XCTAssertEqual(r.store.migrationReports.count, 1)
    }

    func testEmptyLegacyListStillCommitsV2() throws {
        let r = try rig([], files: [:])
        let report = try r.applier.migrateIfNeeded(selectedId: nil, nowEpochSeconds: 0)
        XCTAssertNotNil(report)
        XCTAssertTrue(r.store.isV2)
        XCTAssertTrue(try r.store.allWallets().isEmpty)
    }

    func testRunsOnlyOnce() throws {
        let r = try rig([hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1)],
                        files: ["b-bitcoin.sqlite": 7])
        XCTAssertNotNil(try r.applier.migrateIfNeeded(selectedId: nil, nowEpochSeconds: 0))
        XCTAssertNil(try r.applier.migrateIfNeeded(selectedId: nil, nowEpochSeconds: 0))
        XCTAssertEqual(r.factory.storeMoves.count, 1)
        XCTAssertEqual(r.store.migrationReports.count, 1)
    }

    func testUnrelatedAndNeverMergedRecordsPassThroughUntouched() throws {
        let wif = ManagedWallet(id: "k", label: "Claim", network: .ecashMainnet,
                                externalDescriptor: "pkh(02ab)", internalDescriptor: "pkh(02ab)",
                                keyType: .wif, isBackedUp: true, sortIndex: 2)
        let th = ManagedWallet(id: "t", label: "Thunder", network: .thunder,
                               externalDescriptor: "", internalDescriptor: "", sortIndex: 3)
        let legacy = [hd("a", .ecashMainnet, sort: 0), wif, th]
        let r = try rig(legacy, files: ["a-ecashMainnet.sqlite": 1, "k-ecashMainnet.sqlite": 2])
        _ = try r.applier.migrateIfNeeded(selectedId: "k", nowEpochSeconds: 0)
        XCTAssertEqual(try r.store.allWallets(), legacy)                  // byte-for-byte the same records
        XCTAssertTrue(r.factory.storeMoves.isEmpty)
    }

    // MARK: - A failing store backs out ONLY that record (I2/I3/I4)

    func testStoreThatWontOpenBeforeTheMoveStaysStandalone() throws {
        let r = try rig([hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1), hd("c", .signet, sort: 2)],
                        files: ["b-bitcoin.sqlite": 5, "c-signet.sqlite": 9])
        r.factory.failingStores = ["b-bitcoin.sqlite"]                     // foreign/corrupt store

        let report = try XCTUnwrap(try r.applier.migrateIfNeeded(selectedId: nil, nowEpochSeconds: 0))

        XCTAssertEqual(try r.store.allWallets().map { $0.id }, ["a", "b"])   // b kept, c merged
        XCTAssertEqual(report.excluded, [MigrationExclusion(legacyId: "b", reason: "load-before")])
        XCTAssertEqual(report.keptStandalone, ["b"])
        XCTAssertEqual(r.factory.storeMoves, ["c-signet.sqlite>a-signet-bip84-0.sqlite"])   // b never moved
        XCTAssertTrue(r.factory.chainDataFiles.contains("b-bitcoin.sqlite"))
        XCTAssertEqual(report.walletId(forLegacy: "c"), "a")
        XCTAssertEqual(report.walletId(forLegacy: "b"), "b")
    }

    func testStoreThatWontReopenAfterTheMoveIsMovedBack() throws {
        let r = try rig([hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1)],
                        files: ["b-bitcoin.sqlite": 5])
        r.factory.failingStores = ["a-bitcoin-bip84-0.sqlite"]            // reopen at the new name fails

        let report = try XCTUnwrap(try r.applier.migrateIfNeeded(selectedId: nil, nowEpochSeconds: 0))

        XCTAssertEqual(report.excluded, [MigrationExclusion(legacyId: "b", reason: "load-after")])
        XCTAssertEqual(r.factory.storeMoves, ["b-bitcoin.sqlite>a-bitcoin-bip84-0.sqlite",
                                              "a-bitcoin-bip84-0.sqlite>b-bitcoin.sqlite"])   // reverted
        XCTAssertEqual(r.factory.chainDataFiles, ["b-bitcoin.sqlite"])
        XCTAssertEqual(r.factory.cachedBalances["b-bitcoin.sqlite"], 5)
        XCTAssertEqual(try r.store.allWallets().map { $0.id }, ["a", "b"])
        XCTAssertTrue(r.store.isV2)                                          // the rest still committed
    }

    func testInterruptedRunResumesWithoutMovingTwice() throws {
        // A previous run moved b's store, then died before commitV2: the store is still legacy, the
        // file is already at its destination. The retry verifies it in place.
        let r = try rig([hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1)],
                        files: ["a-bitcoin-bip84-0.sqlite": 5])          // already moved
        let report = try XCTUnwrap(try r.applier.migrateIfNeeded(selectedId: nil, nowEpochSeconds: 0))
        XCTAssertTrue(r.factory.storeMoves.isEmpty)
        XCTAssertTrue(report.excluded.isEmpty)
        XCTAssertEqual(try r.store.allWallets()[0].accounts.map { $0.storeName },
                       ["a-ecashMainnet.sqlite", "a-bitcoin-bip84-0.sqlite"])
    }

    // MARK: - Scrubbing (Golden Rule §2)

    func testReportNeverContainsLabelsOrDescriptors() throws {
        let r = try rig([hd("a", .ecashMainnet, sort: 0, label: "CANARY LABEL"),
                         hd("b", .bitcoin, sort: 1, label: "CANARY TWO")],
                        files: ["b-bitcoin.sqlite": 5])
        r.factory.failingStores = []
        _ = try r.applier.migrateIfNeeded(selectedId: "b", nowEpochSeconds: 0)
        let json = try XCTUnwrap(String(data: try XCTUnwrap(r.store.migrationReports.first), encoding: .utf8))
        for forbidden in ["CANARY", "xpub", "tpub", "wpkh", "[d34db33f", "abandon", "xprv", "tprv"] {
            XCTAssertFalse(json.contains(forbidden), "report leaked \(forbidden)")
        }
        XCTAssertTrue(json.contains("b-bitcoin.sqlite"))                     // ids + store names are the content
    }
}
