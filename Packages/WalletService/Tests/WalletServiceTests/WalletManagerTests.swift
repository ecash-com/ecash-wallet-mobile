// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// WalletManager orchestration, driven by in-memory stores + the mock factory (Robolectric-safe).
/// Real BDK create/import + Keychain/SQLite are integration-tested on device/emulator (§11).
final class WalletManagerTests: XCTestCase {

    func testCreateWalletPersistsSecretAndMetadataAndSelects() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())

        let wallet = try manager.createWallet(label: "Savings", network: .signet)

        XCTAssertEqual(manager.wallets.count, 1)
        XCTAssertEqual(manager.selectedWalletId, wallet.id)
        XCTAssertEqual(wallet.network, WalletNetwork.signet)
        XCTAssertFalse(wallet.isBackedUp)
        XCTAssertNotNil(try ks.loadMnemonic(walletId: wallet.id))   // secret stored
        XCTAssertEqual(try ws.allWallets().count, 1)                // metadata stored
    }

    func testImportWalletStoresGivenMnemonic() throws {
        let ks = InMemoryKeyStore()
        let manager = WalletManager(keyStore: ks, walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

        let wallet = try manager.importWallet(label: "Imported", network: .signet, mnemonic: mnemonic)

        XCTAssertEqual(try ks.loadMnemonic(walletId: wallet.id), mnemonic)
        XCTAssertEqual(manager.wallets.count, 1)
        // Imported wallets are already backed up (the user supplied the seed) → no backup nudge,
        // unlike a freshly CREATED wallet (asserted false above).
        XCTAssertTrue(wallet.isBackedUp)
    }

    func testImportRejectsBadMnemonicAndPersistsNothing() {
        let factory = MockWalletEngineFactory()
        factory.rejectImport = true
        let ks = InMemoryKeyStore()
        let manager = WalletManager(keyStore: ks, walletStore: InMemoryWalletStore(), factory: factory)

        var threw = false
        do { _ = try manager.importWallet(label: "X", network: .signet, mnemonic: "bad checksum") }
        catch { threw = true }

        XCTAssertTrue(threw)
        XCTAssertEqual(manager.wallets.count, 0)
    }

    // MARK: - Import private key (WIF)

    func testImportPrivateKeyCreatesWifWalletBackedUpAndStoresSecret() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        let wif = "Kzjzb4aapsgaqrrVuDe6DongJbMxrq7pyLTwRWoeGJU5hHKUekWj"

        let wallet = try manager.importPrivateKey(label: "Claimed", network: .ecash, wif: wif)

        XCTAssertEqual(wallet.keyType, WalletKeyType.wif)      // single-key wallet
        XCTAssertTrue(wallet.isBackedUp)                        // user holds the WIF → no nudge
        XCTAssertEqual(wallet.network, WalletNetwork.ecash)
        XCTAssertEqual(try ks.loadMnemonic(walletId: wallet.id), wif)  // the WIF is the stored secret
        XCTAssertEqual(manager.selectedWalletId, wallet.id)
        XCTAssertEqual(try ws.allWallets().count, 1)
        // Single key → one address, external == internal.
        XCTAssertEqual(wallet.externalDescriptor, wallet.internalDescriptor)
    }

    func testImportPrivateKeyRejectsBadKeyAndPersistsNothing() {
        let factory = MockWalletEngineFactory()
        factory.rejectPrivateKey = true
        let ks = InMemoryKeyStore()
        let manager = WalletManager(keyStore: ks, walletStore: InMemoryWalletStore(), factory: factory)

        var threw = false
        do { _ = try manager.importPrivateKey(label: "X", network: .ecash, wif: "not-a-wif") }
        catch { threw = true }

        XCTAssertTrue(threw)
        XCTAssertEqual(manager.wallets.count, 0)
    }

    func testPreviewAddressForWIF() throws {
        let factory = MockWalletEngineFactory()
        factory.previewAddressToReturn = "14kwDb3YYj6cdhz9fxGftn1Uga5vdtfrxP"
        let manager = WalletManager(keyStore: InMemoryKeyStore(),
                                    walletStore: InMemoryWalletStore(), factory: factory)
        let addr = try manager.previewAddress(forWIF: "Kzjzb4…", network: .ecash)
        XCTAssertEqual(addr, "14kwDb3YYj6cdhz9fxGftn1Uga5vdtfrxP")
    }

    func testRemovePurgesSecretAndMetadataAndReselects() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let factory = MockWalletEngineFactory()
        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: factory)
        let a = try manager.createWallet(label: "A", network: .signet)
        let b = try manager.createWallet(label: "B", network: .signet)
        manager.select(id: a.id)

        try manager.removeWallet(id: a.id)

        XCTAssertNil(try ks.loadMnemonic(walletId: a.id))      // mnemonic purged
        XCTAssertEqual(manager.wallets.count, 1)
        XCTAssertEqual(manager.selectedWalletId, b.id)         // re-selected the survivor
        XCTAssertNotNil(try ks.loadMnemonic(walletId: b.id))   // other wallet untouched (isolation)
        XCTAssertEqual(try ws.allWallets().count, 1)
        // BDK chain-data store is the third keyed artifact — removal must purge it too (Golden Rule §5).
        XCTAssertEqual(factory.purgedChainDataIds, [a.id])
        XCTAssertFalse(factory.purgedChainDataIds.contains(b.id))   // survivor's data untouched
    }

    func testRename() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let wallet = try manager.createWallet(label: "Old", network: .signet)
        try manager.renameWallet(id: wallet.id, to: "New")
        XCTAssertEqual(manager.wallets.first?.label, "New")
    }

    func testSetBackedUp() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let wallet = try manager.createWallet(label: "A", network: .signet)
        XCTAssertFalse(manager.wallets.first?.isBackedUp ?? true)
        try manager.setBackedUp(id: wallet.id)
        XCTAssertTrue(manager.wallets.first?.isBackedUp ?? false)
    }

    func testLoadRestoresWalletsAndSelection() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let first = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        _ = try first.createWallet(label: "A", network: .signet)
        _ = try first.createWallet(label: "B", network: .signet)

        // A fresh manager over the same stores loads what was persisted.
        let reloaded = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        try reloaded.load()
        XCTAssertEqual(reloaded.wallets.count, 2)
        XCTAssertNotNil(reloaded.selectedWalletId)
    }

    func testEngineForWalletMatchesNetwork() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let wallet = try manager.createWallet(label: "A", network: .signet)
        let engine = try manager.engine(for: wallet)
        // `WalletNetwork.signet` written out: `engine` is a `WalletEngineProtocol` existential, so
        // inside the generic `XCTAssertEqual` the transpiler can't infer the shorthand's owning type
        // (it emitted `Any.signet`). Explicit qualification is the documented workaround.
        XCTAssertEqual(engine.network, WalletNetwork.signet)
    }

    // MARK: - Backend resolution precedence (user override → remote default → bundled)

    /// The remote endpoints config applies BELOW a user override and ABOVE the bundled default, and
    /// a malformed remote entry is a safe no-op. Exercised on `.ecash` to avoid other tests' state.
    func testBackendResolutionPrecedence() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(),
                                    walletStore: InMemoryWalletStore(),
                                    factory: MockWalletEngineFactory())
        // Start clean (UserDefaults.standard is process-global).
        manager.clearBackendOverride(network: WalletNetwork.ecash)
        manager.clearRemoteBackendDefaults()
        defer {
            manager.clearBackendOverride(network: WalletNetwork.ecash)
            manager.clearRemoteBackendDefaults()
        }

        // 3. Bundled default: eCash → Esplora at the drynet3 root URL.
        var resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.kind, WalletBackend.Kind.esplora)
        XCTAssertEqual(resolved.url, "https://esplora.drynet3.drivechain.dev")

        // A malformed remote entry (bad kind) must NOT change resolution.
        manager.setRemoteBackendDefault(network: WalletNetwork.ecash, kind: "bogus", url: "https://x")
        resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.url, "https://esplora.drynet3.drivechain.dev")

        // 2. Remote default now wins over bundled.
        manager.setRemoteBackendDefault(network: WalletNetwork.ecash,
                                        kind: "esplora", url: "https://esplora.example.test")
        resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.url, "https://esplora.example.test")

        // 1. User override beats the remote default.
        manager.setBackendOverride(network: WalletNetwork.ecash,
                                   kind: "electrum", url: "ssl://user.example.test:50002")
        resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.kind, WalletBackend.Kind.electrum)
        XCTAssertEqual(resolved.url, "ssl://user.example.test:50002")
        // A user override is reported as such; a remote default is NOT.
        XCTAssertTrue(manager.hasBackendOverride(for: WalletNetwork.ecash))

        // Clearing the user override falls back to the remote default (not straight to bundled).
        manager.clearBackendOverride(network: WalletNetwork.ecash)
        resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.url, "https://esplora.example.test")
        XCTAssertFalse(manager.hasBackendOverride(for: WalletNetwork.ecash))

        // Clearing remote defaults returns to the bundled default.
        manager.clearRemoteBackendDefaults()
        resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.url, "https://esplora.drynet3.drivechain.dev")
    }
}
