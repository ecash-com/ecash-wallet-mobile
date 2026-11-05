// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import Foundation
@testable import WalletService

/// WalletStore semantics: in-memory store + the JSON-file store round-trip.
final class WalletStoreTests: XCTestCase {

    private func wallet(id: String, sort: Int, label: String = "W", network: WalletNetwork = .signet) -> ManagedWallet {
        ManagedWallet(id: id, label: label, network: network,
                      externalDescriptor: "wpkh(\(id)/0/*)", internalDescriptor: "wpkh(\(id)/1/*)",
                      isBackedUp: false, sortIndex: sort)
    }

    func testUpsertAndOrderingBySortIndex() throws {
        let ws = InMemoryWalletStore()
        try ws.upsertWallet(wallet(id: "b", sort: 1))
        try ws.upsertWallet(wallet(id: "a", sort: 0))
        let ids = try ws.allWallets().map { $0.id }
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testUpsertUpdatesExisting() throws {
        let ws = InMemoryWalletStore()
        try ws.upsertWallet(wallet(id: "a", sort: 0, label: "Old"))
        try ws.upsertWallet(wallet(id: "a", sort: 0, label: "New"))
        let all = try ws.allWallets()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.label, "New")
    }

    func testDeleteAndDeleteAll() throws {
        let ws = InMemoryWalletStore()
        try ws.upsertWallet(wallet(id: "a", sort: 0))
        try ws.upsertWallet(wallet(id: "b", sort: 1))
        try ws.deleteWallet(id: "a")
        XCTAssertEqual(try ws.allWallets().map { $0.id }, ["b"])
        try ws.deleteAll()
        XCTAssertTrue(try ws.allWallets().isEmpty)
    }

    func testRoundTripPreservesFields() throws {
        let ws = InMemoryWalletStore()
        let w = ManagedWallet(id: "x", label: "Savings", network: .signet,
                              externalDescriptor: "ext", internalDescriptor: "int",
                              isBackedUp: true, sortIndex: 3)
        try ws.upsertWallet(w)
        XCTAssertEqual(try ws.allWallets().first, w)
    }

    func testFileWalletStoreRoundTrip() throws {
        // Skipped on the transpiled (Android) side — same gating as the real-BDK tests (§11).
        // Robolectric's simulated filesystem doesn't reliably round-trip real `Data.write(to:)` /
        // `Data(contentsOf:)` to the temp dir, so a fresh store reads back empty there (a false
        // negative — the decode `try?` swallows it). This is a runtime/IO-touching test that belongs
        // on a real runtime: it runs and passes on the iOS host, and FileWalletStore persistence on
        // Android must be confirmed on a device/emulator (tracked with the sync/send device TODOs).
        // The InMemoryWalletStore tests above cover the store semantics on every platform.
        #if SKIP
        throw XCTSkip("FileWalletStore does real file IO; verify on a device/emulator, not Robolectric.")
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walletstore-\(UUID().uuidString).json")
        let store = FileWalletStore(fileURL: url)
        defer { try? store.deleteAll() }

        XCTAssertTrue(try store.allWallets().isEmpty)
        try store.upsertWallet(wallet(id: "a", sort: 0, label: "A"))
        try store.upsertWallet(wallet(id: "b", sort: 1, label: "B"))

        // A fresh store over the same file reads back what was written.
        let reopened = FileWalletStore(fileURL: url)
        let all = try reopened.allWallets()
        XCTAssertEqual(all.map { $0.id }, ["a", "b"])
        XCTAssertEqual(all.first?.label, "A")

        try reopened.deleteWallet(id: "a")
        XCTAssertEqual(try FileWalletStore(fileURL: url).allWallets().map { $0.id }, ["b"])
    }

    func testFileWalletStorePersistsKeyType() throws {
        #if SKIP
        throw XCTSkip("FileWalletStore does real file IO; verify on a device/emulator, not Robolectric.")
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walletstore-\(UUID().uuidString).json")
        let store = FileWalletStore(fileURL: url)
        defer { try? store.deleteAll() }

        let wif = ManagedWallet(id: "wif1", label: "Claimed", network: .ecash,
                                externalDescriptor: "pkh(pub)", internalDescriptor: "pkh(pub)",
                                keyType: .wif, isBackedUp: true, sortIndex: 0)
        try store.upsertWallet(wif)                     // .wif
        try store.upsertWallet(wallet(id: "hd1", sort: 1))  // defaults to .mnemonic

        let all = try FileWalletStore(fileURL: url).allWallets()
        XCTAssertEqual(all.first { $0.id == "wif1" }?.keyType, WalletKeyType.wif)
        XCTAssertEqual(all.first { $0.id == "hd1" }?.keyType, WalletKeyType.mnemonic)
    }

    /// Backward compatibility: a `wallets.json` written before `keyType` existed (field absent)
    /// must decode as `.mnemonic`, not fail.
    func testFileWalletStoreDefaultsMissingKeyTypeToMnemonic() throws {
        #if SKIP
        throw XCTSkip("FileWalletStore does real file IO; verify on a device/emulator, not Robolectric.")
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walletstore-\(UUID().uuidString).json")
        // A record with NO keyType key (as older builds wrote).
        let legacyJSON = """
        [{"id":"old","label":"Old","network":"signet","externalDescriptor":"ext",
          "internalDescriptor":"int","isBackedUp":true,"sortIndex":0}]
        """
        try Data(legacyJSON.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let all = try FileWalletStore(fileURL: url).allWallets()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.keyType, WalletKeyType.mnemonic)
    }

    // MARK: - v2 (seed-container) format

    private func tempPair() -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("walletstore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("wallets.json"), dir.appendingPathComponent("wallets.v2.json"))
    }

    private func container(_ id: String) -> ManagedWallet {
        let a = WalletAccount(network: WalletNetwork.ecashMainnet, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                              externalDescriptor: "wpkh([d34db33f/84'/0'/0']xpub/0/*)",
                              internalDescriptor: "wpkh([d34db33f/84'/0'/0']xpub/1/*)",
                              storeName: "\(id)-ecashMainnet.sqlite")
        let b = WalletAccount(network: WalletNetwork.bitcoin, scriptType: ScriptType.bip86, accountIndex: Int32(0),
                              externalDescriptor: "tr([d34db33f/86'/0'/0']xpub/0/*)",
                              internalDescriptor: "tr([d34db33f/86'/0'/0']xpub/1/*)",
                              storeName: "\(id)-bitcoin-bip86-0.sqlite")
        return ManagedWallet(id: id, label: "Seed", keyType: WalletKeyType.mnemonic, isBackedUp: true, sortIndex: 1,
                             selectedAccountId: b.id, accounts: [a, b],
                             mergedFrom: ["old-copy"], orphanKeychainIds: ["old-copy"])
    }

    func testInMemoryCommitV2ReplacesTheList() throws {
        let ws = InMemoryWalletStore()
        try ws.upsertWallet(wallet(id: "legacy", sort: 0))
        try ws.commitV2([container("c")])
        XCTAssertEqual(try ws.allWallets(), [container("c")])
    }

    func testCommitV2SwitchesModeAndFreezesTheLegacyFile() throws {
        #if SKIP
        throw XCTSkip("FileWalletStore does real file IO; verify on a device/emulator, not Robolectric.")
        #endif
        let (legacy, v2) = tempPair()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        let store = FileWalletStore(legacyURL: legacy, v2URL: v2)
        try store.upsertWallet(wallet(id: "a", sort: 0, label: "A"))
        XCTAssertFalse(store.isV2)
        let legacyBytes = try Data(contentsOf: legacy)

        try store.commitV2([container("a")])
        XCTAssertTrue(store.isV2)
        XCTAssertEqual(try store.allWallets(), [container("a")])          // full round trip, every field

        // Writes after the switch go to v2 only; the legacy file is byte-identical (downgrade safety).
        try store.upsertWallet(wallet(id: "b", sort: 2, label: "B"))
        try store.deleteWallet(id: "a")
        XCTAssertEqual(try FileWalletStore(legacyURL: legacy, v2URL: v2).allWallets().map { $0.id }, ["b"])
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)

        // deleteAll keeps the store in v2 mode — the frozen legacy list must never come back.
        try store.deleteAll()
        XCTAssertTrue(store.isV2)
        XCTAssertTrue(try store.allWallets().isEmpty)
    }

    func testV2DecodesLenientlyAndSkipsAnAccountlessRecord() throws {
        #if SKIP
        throw XCTSkip("FileWalletStore does real file IO; verify on a device/emulator, not Robolectric.")
        #endif
        let (legacy, v2) = tempPair()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        // A v2 file from a NEWER build: unknown keys, missing optional keys, and one corrupt record.
        let json = """
        {"version": 3, "futureFlag": true, "wallets": [
          {"id":"w","label":"W","isBackedUp":false,"sortIndex":0,"newField":"x",
           "accounts":[{"id":"ecashMainnet-bip84-0","network":"ecashMainnet","scriptType":"bip84","accountIndex":0,
                        "externalDescriptor":"e","internalDescriptor":"i","storeName":"w-ecashMainnet.sqlite","extra":1}]},
          {"id":"broken","label":"B","isBackedUp":false,"sortIndex":1,"accounts":[]}
        ]}
        """
        try Data(json.utf8).write(to: v2)
        let all = try FileWalletStore(legacyURL: legacy, v2URL: v2).allWallets()
        XCTAssertEqual(all.map { $0.id }, ["w"])
        XCTAssertEqual(all[0].keyType, WalletKeyType.mnemonic)
        XCTAssertEqual(all[0].selectedAccountId, "ecashMainnet-bip84-0")   // defaulted to the first account
        XCTAssertTrue(all[0].mergedFrom.isEmpty)
    }

    func testLegacyModeRefusesAMultiAccountWallet() throws {
        #if SKIP
        throw XCTSkip("FileWalletStore does real file IO; verify on a device/emulator, not Robolectric.")
        #endif
        let (legacy, v2) = tempPair()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        let store = FileWalletStore(legacyURL: legacy, v2URL: v2)
        do {
            try store.upsertWallet(container("c"))
            XCTFail("a two-account wallet can't be written in legacy mode")
        } catch {
            XCTAssertEqual(error as? WalletError, WalletError.persistenceFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))   // nothing half-written
        XCTAssertFalse(store.isV2)
    }
}
