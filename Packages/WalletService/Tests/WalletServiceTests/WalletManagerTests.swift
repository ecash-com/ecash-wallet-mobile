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

    /// `effectiveDefaultBackendURL` is what a network resolves to with NO user override — the remote
    /// default when applied, else the bundled one.
    ///
    /// It exists because the Settings editor decides "is the user still on the default?" by
    /// comparison, and comparing against the BUNDLED value is wrong once a remote default is in
    /// play. That bug made Bitcoin unsettable: its bundled default is Blockstream, so entering that
    /// URL was read as "back to default", the override was deleted, and the remote Esplora took
    /// over — looking exactly like the setting refusing to save.
    func testEffectiveDefaultFollowsTheRemoteDefaultNotTheBundledOne() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(),
                                    walletStore: InMemoryWalletStore(),
                                    factory: MockWalletEngineFactory())
        manager.clearBackendOverride(network: WalletNetwork.ecash)
        manager.clearRemoteBackendDefaults()
        defer {
            manager.clearBackendOverride(network: WalletNetwork.ecash)
            manager.clearRemoteBackendDefaults()
        }

        // No remote default yet → the bundled value.
        XCTAssertEqual(manager.effectiveDefaultBackendURL(for: WalletNetwork.ecash),
                       "https://esplora.alpha.ecash.ninja")

        // Once a remote default lands, THAT is what "no override" means.
        manager.setRemoteBackendDefault(network: WalletNetwork.ecash,
                                        kind: "electrum", url: "ssl://remote.example.test:50002")
        XCTAssertEqual(manager.effectiveDefaultBackendURL(for: WalletNetwork.ecash),
                       "ssl://remote.example.test:50002")
        XCTAssertEqual(manager.effectiveDefaultBackendKind(for: WalletNetwork.ecash), "electrum")
        // The bundled accessor keeps reporting the bundled value — the two are different questions.
        XCTAssertEqual(manager.defaultBackendURL(for: WalletNetwork.ecash),
                       "https://esplora.alpha.ecash.ninja")

        // And the bundled URL is now just another URL a user may pin as an override.
        manager.setBackendOverride(network: WalletNetwork.ecash,
                                   kind: "esplora", url: "https://esplora.alpha.ecash.ninja")
        XCTAssertEqual(manager.resolvedBackend(for: WalletNetwork.ecash).url,
                       "https://esplora.alpha.ecash.ninja")
        XCTAssertTrue(manager.hasBackendOverride(for: WalletNetwork.ecash))
    }

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

        // 3. Bundled default: eCash → Esplora at the alphanet root URL.
        var resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.kind, WalletBackend.Kind.esplora)
        XCTAssertEqual(resolved.url, "https://esplora.alpha.ecash.ninja")

        // A malformed remote entry (bad kind) must NOT change resolution.
        manager.setRemoteBackendDefault(network: WalletNetwork.ecash, kind: "bogus", url: "https://x")
        resolved = manager.resolvedBackend(for: WalletNetwork.ecash)
        XCTAssertEqual(resolved.url, "https://esplora.alpha.ecash.ninja")

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
        XCTAssertEqual(resolved.url, "https://esplora.alpha.ecash.ninja")
    }

    // MARK: - Copy to another network (docs/copy-wallet-to-network.md)

    private static let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    /// Runs `body` and returns the `WalletError` it threw, or nil. SkipUnit has no XCTAssertThrowsError.
    private func copyError(_ body: () throws -> Void) -> WalletError? {
        do { try body(); return nil }
        catch let error as WalletError { return error }
        catch { return .engine("unexpected") }
    }

    func testCopyTargetsAreTheSharedKeyNetworksOnly() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let alpha = try manager.importWallet(label: "A", network: .ecash, mnemonic: Self.phrase)
        let signet = try manager.importWallet(label: "S", network: .signet, mnemonic: Self.phrase)

        // Offered targets only (`selectable`): betanet shares the keys but was retired 2026-10-30.
        XCTAssertEqual(manager.copyTargets(for: alpha.id), [WalletNetwork.ecashMainnet, WalletNetwork.bitcoin])
        // Signet is coin-type 1': a "copy" would have different addresses, so nothing is offered.
        XCTAssertTrue(manager.copyTargets(for: signet.id).isEmpty)
        XCTAssertTrue(manager.copyTargets(for: "missing").isEmpty)
    }

    func testCopyWalletCreatesAnIndependentWalletWithItsOwnSecret() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        let alpha = try manager.importWallet(label: "Savings", network: .ecash, mnemonic: Self.phrase, scriptType: .bip86)

        let beta = try manager.copyWallet(id: alpha.id, to: .ecashMainnet, label: "Savings")

        XCTAssertNotEqual(beta.id, alpha.id)
        XCTAssertEqual(beta.network, WalletNetwork.ecashMainnet)
        XCTAssertEqual(beta.label, "Savings")
        XCTAssertEqual(beta.scriptType, ScriptType.bip86)           // derivation carried over
        XCTAssertEqual(beta.externalDescriptor, alpha.externalDescriptor)
        XCTAssertEqual(beta.isBackedUp, alpha.isBackedUp)
        XCTAssertEqual(try ks.loadMnemonic(walletId: beta.id), Self.phrase)   // its OWN Keychain entry
        XCTAssertEqual(manager.selectedWalletId, beta.id)
        XCTAssertEqual(try ws.allWallets().count, 2)
        XCTAssertEqual(manager.existingCopy(of: alpha.id, on: .ecashMainnet)?.id, beta.id)
    }

    func testCopyInheritsNotBackedUp() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let created = try manager.createWallet(label: "New", network: .ecash)   // created → not backed up

        let copy = try manager.copyWallet(id: created.id, to: .ecashMainnet, label: "New")

        // Same phrase, same (unmet) backup obligation — the copy must keep nagging too.
        XCTAssertFalse(copy.isBackedUp)
    }

    func testCopyWIFWalletUsesThePrivateKeyPath() throws {
        let ks = InMemoryKeyStore()
        let manager = WalletManager(keyStore: ks, walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let wif = "Kzjzb4aapsgaqrrVuDe6DongJbMxrq7pyLTwRWoeGJU5hHKUekWj"
        let claim = try manager.importPrivateKey(label: "Claim", network: .ecash, wif: wif)

        let copy = try manager.copyWallet(id: claim.id, to: .ecashMainnet, label: "Claim")

        XCTAssertEqual(copy.keyType, WalletKeyType.wif)
        XCTAssertEqual(copy.externalDescriptor, claim.externalDescriptor)
        XCTAssertEqual(try ks.loadMnemonic(walletId: copy.id), wif)
    }

    func testRemovingOneCopyLeavesTheOtherIntact() throws {
        let ks = InMemoryKeyStore()
        let factory = MockWalletEngineFactory()
        let manager = WalletManager(keyStore: ks, walletStore: InMemoryWalletStore(), factory: factory)
        let alpha = try manager.importWallet(label: "A", network: .ecash, mnemonic: Self.phrase)
        let beta = try manager.copyWallet(id: alpha.id, to: .ecashMainnet, label: "A")

        try manager.removeWallet(id: alpha.id)

        // The whole point of copying the secret instead of sharing it: the survivor keeps its key.
        XCTAssertEqual(try ks.loadMnemonic(walletId: beta.id), Self.phrase)
        XCTAssertNil(try ks.loadMnemonic(walletId: alpha.id))
        XCTAssertEqual(factory.purgedChainDataIds, [alpha.id])
        XCTAssertEqual(manager.wallets.map { $0.id }, [beta.id])
    }

    func testCopyRefusesUnsupportedTargetsAndPersistsNothing() throws {
        let ws = InMemoryWalletStore()
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: ws, factory: MockWalletEngineFactory())
        let alpha = try manager.importWallet(label: "A", network: .ecash, mnemonic: Self.phrase)

        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: alpha.id, to: .signet, label: "A") }, .copyNotSupported)
        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: alpha.id, to: .thunder, label: "A") }, .copyNotSupported)
        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: alpha.id, to: .ecash, label: "A") }, .copyNotSupported)
        // Betanet shares alphanet's keys but is retired from the picker (2026-10-30): no new wallets on it.
        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: alpha.id, to: .ecashBeta, label: "A") }, .copyNotSupported)
        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: "missing", to: .ecashMainnet, label: "A") }, .copyNotSupported)
        XCTAssertEqual(try ws.allWallets().count, 1)
        XCTAssertEqual(manager.selectedWalletId, alpha.id)
    }

    func testCopyRefusesASecondCopyOnTheSameNetwork() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let alpha = try manager.importWallet(label: "A", network: .ecash, mnemonic: Self.phrase)
        _ = try manager.copyWallet(id: alpha.id, to: .ecashMainnet, label: "A")

        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: alpha.id, to: .ecashMainnet, label: "A") }, .alreadyOnNetwork)
        XCTAssertEqual(manager.wallets.count, 2)
    }

    func testExistingCopyIgnoresADifferentWalletOnThatNetwork() throws {
        let manager = WalletManager(keyStore: InMemoryKeyStore(), walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let alpha = try manager.importWallet(label: "A", network: .ecash, mnemonic: Self.phrase)
        // Different keys (a single-key WIF wallet) on the target network: not a copy of `alpha`.
        _ = try manager.importPrivateKey(label: "Other", network: .ecashMainnet,
                                         wif: "Kzjzb4aapsgaqrrVuDe6DongJbMxrq7pyLTwRWoeGJU5hHKUekWj")

        XCTAssertNil(manager.existingCopy(of: alpha.id, on: .ecashMainnet))
    }

    func testCopyWithDivergentKeysPersistsNothing() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let factory = MockWalletEngineFactory()
        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: factory)
        let alpha = try manager.importWallet(label: "A", network: .ecash, mnemonic: Self.phrase)
        factory.divergentRestoreNetworks = [.ecashMainnet]

        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: alpha.id, to: .ecashMainnet, label: "A") }, .copyMismatch)
        XCTAssertEqual(manager.wallets.count, 1)
        XCTAssertEqual(try ws.allWallets().count, 1)
        XCTAssertEqual(manager.selectedWalletId, alpha.id)
    }

    func testCopyWithoutAStoredSecretFails() throws {
        let ks = InMemoryKeyStore()
        let manager = WalletManager(keyStore: ks, walletStore: InMemoryWalletStore(), factory: MockWalletEngineFactory())
        let alpha = try manager.importWallet(label: "A", network: .ecash, mnemonic: Self.phrase)
        try ks.deleteMnemonic(walletId: alpha.id)

        XCTAssertEqual(copyError { _ = try manager.copyWallet(id: alpha.id, to: .ecashMainnet, label: "A") }, .keyUnavailable)
        XCTAssertEqual(manager.wallets.count, 1)
    }

    func testCopyErrorMessagesCarryNoSecret() {
        for error in [WalletError.copyNotSupported, .alreadyOnNetwork, .copyMismatch, .keyUnavailable] {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertFalse(error.userMessage.contains("abandon"))
            XCTAssertFalse(error.userMessage.contains("wpkh"))
        }
    }

    // MARK: - Seed-container migration at load (docs/seed-container-model.md §6)

    private func legacyRecord(_ id: String, _ network: WalletNetwork, sort: Int) -> ManagedWallet {
        let coin = network == .signet ? "1" : "0"
        return ManagedWallet(id: id, label: "W", network: network,
                             externalDescriptor: "wpkh([d34db33f/84'/\(coin)'/0']xpub\(id)/0/*)",
                             internalDescriptor: "wpkh([d34db33f/84'/\(coin)'/0']xpub\(id)/1/*)",
                             sortIndex: sort)
    }

    func testLoadRunsTheMigrationOnceAndMapsTheSavedSelection() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let factory = MockWalletEngineFactory()
        try ws.upsertWallet(legacyRecord("orig", .ecashMainnet, sort: 0))
        try ws.upsertWallet(legacyRecord("copy", .bitcoin, sort: 1))
        try ks.saveMnemonic("phrase", walletId: "orig")
        try ks.saveMnemonic("phrase", walletId: "copy")
        factory.chainDataFiles = ["copy-bitcoin.sqlite"]
        factory.cachedBalances["copy-bitcoin.sqlite"] = 42

        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: factory)
        try manager.load(savedSelectedId: "copy")                     // the app's persisted choice was the copy

        XCTAssertTrue(ws.isV2)
        XCTAssertEqual(manager.wallets.map { $0.id }, ["orig"])
        XCTAssertEqual(manager.selectedWalletId, "orig")
        XCTAssertEqual(manager.selectedWallet?.selectedAccountId, "bitcoin-bip84-0")
        XCTAssertEqual(manager.migratedWalletId(forLegacy: "copy"), "orig")
        XCTAssertEqual(manager.migratedWalletId(forLegacy: "orig"), "orig")
        XCTAssertNil(manager.migratedWalletId(forLegacy: "nope"))
        // The migration never touched a Keychain entry (I1): both phrases are still there.
        XCTAssertEqual(try ks.loadMnemonic(walletId: "copy"), "phrase")
        XCTAssertEqual(try ks.loadMnemonic(walletId: "orig"), "phrase")

        // A second load is an ordinary load.
        try manager.load(savedSelectedId: "orig")
        XCTAssertEqual(factory.storeMoves.count, 1)
        XCTAssertEqual(ws.migrationReports.count, 1)
    }

    func testRemoveWalletPurgesTheOrphanKeychainEntriesButNeverALiveWallet() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let a = WalletAccount(network: WalletNetwork.ecashMainnet, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                              externalDescriptor: "e", internalDescriptor: "i", storeName: "m-ecashMainnet.sqlite")
        let merged = ManagedWallet(id: "m", label: "Merged", keyType: WalletKeyType.mnemonic, isBackedUp: true, sortIndex: 0,
                                   selectedAccountId: a.id, accounts: [a],
                                   mergedFrom: ["old", "other"], orphanKeychainIds: ["old", "other"])
        try ws.commitV2([merged, legacyRecord("other", .signet, sort: 1)])   // "other" is somehow still live
        try ks.saveMnemonic("same phrase", walletId: "m")
        try ks.saveMnemonic("same phrase", walletId: "old")                   // a true duplicate
        try ks.saveMnemonic("phrase-other", walletId: "other")

        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        try manager.load()
        try manager.removeWallet(id: "m")

        XCTAssertNil(try ks.loadMnemonic(walletId: "m"))
        XCTAssertNil(try ks.loadMnemonic(walletId: "old"))                  // proven duplicate: went with it
        XCTAssertEqual(try ks.loadMnemonic(walletId: "other"), "phrase-other")   // a live wallet's entry never
        XCTAssertEqual(manager.wallets.map { $0.id }, ["other"])
    }

    /// Guard 1: an orphan entry whose content differs from the wallet's own is NEVER deleted — even
    /// though the record lists it. This is what makes a (2^-32) fingerprint collision harmless.
    func testRemoveWalletLeavesAnOrphanEntryThatIsNotADuplicate() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let a = WalletAccount(network: WalletNetwork.ecashMainnet, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                              externalDescriptor: "e", internalDescriptor: "i", storeName: "m-ecashMainnet.sqlite")
        let merged = ManagedWallet(id: "m", label: "Merged", keyType: WalletKeyType.mnemonic, isBackedUp: true, sortIndex: 0,
                                   selectedAccountId: a.id, accounts: [a],
                                   mergedFrom: ["dup", "stranger"], orphanKeychainIds: ["dup", "stranger"])
        try ws.commitV2([merged])
        try ks.saveMnemonic("same phrase", walletId: "m")
        try ks.saveMnemonic("same phrase", walletId: "dup")
        try ks.saveMnemonic("a DIFFERENT seed", walletId: "stranger")

        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        try manager.load()
        try manager.removeWallet(id: "m")

        XCTAssertNil(try ks.loadMnemonic(walletId: "m"))
        XCTAssertNil(try ks.loadMnemonic(walletId: "dup"))
        XCTAssertEqual(try ks.loadMnemonic(walletId: "stranger"), "a DIFFERENT seed")   // untouched
    }

    /// Guard 1, corner: if the wallet's own entry is already gone, nothing can be proven, so no
    /// orphan is deleted at all.
    func testRemoveWalletWithoutItsOwnEntryDeletesNoOrphan() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let a = WalletAccount(network: WalletNetwork.ecashMainnet, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                              externalDescriptor: "e", internalDescriptor: "i", storeName: "m-ecashMainnet.sqlite")
        try ws.commitV2([ManagedWallet(id: "m", label: "M", keyType: WalletKeyType.mnemonic, isBackedUp: true, sortIndex: 0,
                                       selectedAccountId: a.id, accounts: [a],
                                       mergedFrom: ["spare"], orphanKeychainIds: ["spare"])])
        try ks.saveMnemonic("same phrase", walletId: "spare")                 // only the spare exists

        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        try manager.load()
        try manager.removeWallet(id: "m")
        XCTAssertEqual(try ks.loadMnemonic(walletId: "spare"), "same phrase")
    }

    /// Guard 2: reveal and signing fall back to the spare copy when the wallet's own entry is missing.
    func testSecretFallsBackToTheOrphanCopyWhenTheOwnEntryIsMissing() throws {
        let ks = InMemoryKeyStore()
        let ws = InMemoryWalletStore()
        let a = WalletAccount(network: WalletNetwork.ecashMainnet, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                              externalDescriptor: "e", internalDescriptor: "i", storeName: "m-ecashMainnet.sqlite")
        try ws.commitV2([ManagedWallet(id: "m", label: "M", keyType: WalletKeyType.mnemonic, isBackedUp: true, sortIndex: 0,
                                       selectedAccountId: a.id, accounts: [a],
                                       mergedFrom: ["spare"], orphanKeychainIds: ["spare"])])
        try ks.saveMnemonic("the phrase", walletId: "spare")

        let manager = WalletManager(keyStore: ks, walletStore: ws, factory: MockWalletEngineFactory())
        try manager.load()
        XCTAssertEqual(try manager.mnemonic(for: "m"), "the phrase")       // reveal works
        try ks.saveMnemonic("own phrase", walletId: "m")
        XCTAssertEqual(try manager.mnemonic(for: "m"), "own phrase")       // own entry wins when present
        // A wallet with no entries at all still reveals nothing — the fallback never widens beyond
        // this wallet's own orphan ids.
        try ks.deleteMnemonic(walletId: "m")
        try ks.deleteMnemonic(walletId: "spare")
        XCTAssertNil(try manager.mnemonic(for: "m"))
    }
}
