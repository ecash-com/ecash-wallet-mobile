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
}
