// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import WalletService

// Real-BDK, host only (like OwnChangeBalanceTests): builds BDK stores directly, so it's excluded
// from the transpile. The same flow must be confirmed on a device/emulator before 1.5.0 ships
// (docs/seed-container-model.md §9, manual upgrade matrix).
#if !SKIP
import BitcoinDevKit

/// The seed-container migration end to end over REAL BDK SQLite stores and the real file store:
/// a funded legacy store moves to its account name with its balance intact, the legacy list is
/// snapshotted byte-for-byte, the report lands on disk without a descriptor in it, a second launch
/// is a no-op — and a store that belongs to a different seed is refused and left where it was.
final class MigrationApplierBDKTests: XCTestCase {
    private static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let otherMnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"

    private var dir: URL!
    private var chainDir: URL!
    private var factory: BDKWalletEngineFactory!
    private var store: FileWalletStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        chainDir = dir.appendingPathComponent("chaindata", isDirectory: true)
        try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)
        factory = BDKWalletEngineFactory(chainDataDirectory: chainDir)
        store = FileWalletStore(fileURL: dir.appendingPathComponent("wallets.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    /// Legacy tx: version 2, one dummy input, one output to `script`, locktime 0.
    private static func fundingTx(sats: UInt64, to script: Data) -> Data {
        var bytes = Data([0x02, 0x00, 0x00, 0x00])
        bytes.append(0x01)
        bytes.append(Data(repeating: 0x11, count: 32))
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bytes.append(0x00)
        bytes.append(contentsOf: [0xff, 0xff, 0xff, 0xff])
        bytes.append(0x01)
        bytes.append(contentsOf: withUnsafeBytes(of: sats.littleEndian) { Array($0) })
        bytes.append(UInt8(script.count))
        bytes.append(script)
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return bytes
    }

    /// A legacy record for `mnemonic` on `network`, plus its real BDK store at the legacy name,
    /// funded with `sats` (0 = created but never funded).
    @discardableResult
    private func legacyWallet(id: String, network: WalletNetwork, sort: Int, sats: UInt64,
                              mnemonic: String = MigrationApplierBDKTests.mnemonic,
                              storeDescriptorsFrom storeMnemonic: String? = nil) throws -> ManagedWallet {
        let keys = try factory.restore(network: network, mnemonic: mnemonic, scriptType: .bip84)
        let record = ManagedWallet(id: id, label: "Wallet \(id)", network: network,
                                   externalDescriptor: keys.externalDescriptor,
                                   internalDescriptor: keys.internalDescriptor, sortIndex: sort)
        // The store on disk may belong to ANOTHER seed (the mismatch case).
        let storeKeys = try storeMnemonic.map { try factory.restore(network: network, mnemonic: $0, scriptType: .bip84) } ?? keys
        let net = BDKSeam.network(network)
        let path = chainDir.appendingPathComponent(WalletAccount.legacyStoreName(walletId: id, network: network)).path
        let persister = try Persister.newSqlite(path: path)
        let wallet = try Wallet(descriptor: try Descriptor(descriptor: storeKeys.externalDescriptor, network: net),
                                changeDescriptor: try Descriptor(descriptor: storeKeys.internalDescriptor, network: net),
                                network: net, persister: persister)
        if sats > 0 {
            let script = wallet.revealNextAddress(keychain: .external).address.scriptPubkey().toBytes()
            let tx = try Transaction(transactionBytes: Self.fundingTx(sats: sats, to: script))
            wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: tx, lastSeen: 1_790_000_000)])
        }
        _ = try wallet.persist(persister: persister)
        try store.upsertWallet(record)
        return record
    }

    private func files() -> Set<String> { Set(factory.chainDataFileNames()) }

    // MARK: Tests

    func testFundedCopyMovesWithItsBalanceAndEverythingIsRecorded() throws {
        try legacyWallet(id: "orig", network: .ecashMainnet, sort: 0, sats: 0)
        let copy = try legacyWallet(id: "copy", network: .bitcoin, sort: 1, sats: 123_456)
        let legacyBytes = try Data(contentsOf: store.legacyFileURL)
        let before = try factory.cachedBalance(storeName: "copy-bitcoin.sqlite", account: copy.selectedAccount, keyType: .mnemonic)
        XCTAssertEqual(before, 123_456)

        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: store, factory: factory)
        try manager.load(savedSelectedId: "copy")

        // One wallet, two accounts; the copy's store now lives under the account name, same balance.
        XCTAssertEqual(manager.wallets.map { $0.id }, ["orig"])
        let wallet = try XCTUnwrap(manager.selectedWallet)
        XCTAssertEqual(wallet.selectedAccountId, "bitcoin-bip84-0")
        let moved = try XCTUnwrap(wallet.account(id: "bitcoin-bip84-0"))
        XCTAssertEqual(moved.storeName, "orig-bitcoin-bip84-0.sqlite")
        XCTAssertTrue(files().contains("orig-bitcoin-bip84-0.sqlite"))
        XCTAssertFalse(files().contains("copy-bitcoin.sqlite"))
        XCTAssertEqual(try factory.cachedBalance(storeName: moved.storeName, account: moved, keyType: .mnemonic), 123_456)
        // The engine the app will use opens that store too (I6 — addresses come from the real account).
        XCTAssertTrue(files().contains("orig-ecashMainnet.sqlite"))

        // Legacy list frozen and snapshotted byte-for-byte; v2 committed; report on disk, scrubbed.
        XCTAssertTrue(store.isV2)
        XCTAssertEqual(try Data(contentsOf: store.legacyFileURL), legacyBytes)
        XCTAssertEqual(try Data(contentsOf: store.preV2SnapshotURL), legacyBytes)
        let report = String(decoding: try Data(contentsOf: store.migrationReportURL), as: UTF8.self)
        for forbidden in ["Wallet orig", "Wallet copy", "xpub", "tpub", "wpkh", "abandon"] {
            XCTAssertFalse(report.contains(forbidden), "report leaked \(forbidden)")
        }
        XCTAssertTrue(report.contains("copy-bitcoin.sqlite"))

        // Second launch: nothing moves, nothing is rewritten.
        let reportBytes = try Data(contentsOf: store.migrationReportURL)
        let again = WalletManager(keyStore: InMemoryKeyStore(), walletStore: store, factory: factory)
        try again.load(savedSelectedId: "copy")
        XCTAssertEqual(again.wallets, manager.wallets)
        XCTAssertNil(again.migratedWalletId(forLegacy: "copy"))            // no migration ran this launch
        XCTAssertEqual(try Data(contentsOf: store.migrationReportURL), reportBytes)
    }

    func testStoreOfAnotherSeedIsRefusedAndLeftInPlace() throws {
        try legacyWallet(id: "orig", network: .ecashMainnet, sort: 0, sats: 0)
        // The record says seed A, but the file on disk was written for seed B: BDK's load refuses
        // the descriptor mismatch, so the record stays its own wallet and the file never moves.
        try legacyWallet(id: "copy", network: .bitcoin, sort: 1, sats: 999, storeDescriptorsFrom: Self.otherMnemonic)
        let fileBytes = try Data(contentsOf: chainDir.appendingPathComponent("copy-bitcoin.sqlite"))

        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: store, factory: factory)
        try manager.load(savedSelectedId: "copy")

        XCTAssertEqual(manager.wallets.map { $0.id }, ["orig", "copy"])
        XCTAssertEqual(manager.selectedWalletId, "copy")
        XCTAssertTrue(files().contains("copy-bitcoin.sqlite"))
        XCTAssertFalse(files().contains("orig-bitcoin-bip84-0.sqlite"))
        XCTAssertEqual(try Data(contentsOf: chainDir.appendingPathComponent("copy-bitcoin.sqlite")), fileBytes)
        let report = String(decoding: try Data(contentsOf: store.migrationReportURL), as: UTF8.self)
        XCTAssertTrue(report.contains("load-before"))
        XCTAssertTrue(store.isV2)
    }

    func testProbeNeverCreatesAStore() throws {
        let copy = try legacyWallet(id: "x", network: .bitcoin, sort: 0, sats: 0)
        let probeName = "x-nowhere.sqlite"
        XCTAssertThrowsError(try factory.cachedBalance(storeName: probeName, account: copy.selectedAccount, keyType: .mnemonic))
        XCTAssertFalse(files().contains(probeName))                           // a plain Persister.newSqlite would have made it
    }
}

#endif
