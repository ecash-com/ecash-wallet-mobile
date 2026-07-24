// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// The keys produced when creating or restoring a wallet: the **secret** (a mnemonic for HD
/// wallets, or a WIF private key for `.wif` single-key wallets) plus the PUBLIC (watch) descriptors
/// that get stored in the WalletStore. The secret is what goes into the Keychain; the descriptors
/// are public-only.
///
/// `public` + `// SKIP @nobridge`: reachable from sibling files' transpiled Kotlin, but kept off
/// the JNI bridge (it carries a secret — never expose it across the bridge surface, §2).
// SKIP @nobridge
public struct WalletKeys: Equatable, Sendable {
    /// The secret to persist in the Keychain — a mnemonic phrase, or a WIF for a `.wif` wallet.
    public let secret: String
    public let externalDescriptor: String
    public let internalDescriptor: String

    public init(secret: String, externalDescriptor: String, internalDescriptor: String) {
        self.secret = secret
        self.externalDescriptor = externalDescriptor
        self.internalDescriptor = internalDescriptor
    }
}

/// Abstracts the BDK-crossing work — mnemonic generation/validation, descriptor derivation, and
/// building the live `WalletEngine`. Keeping it behind a protocol lets `WalletManager`'s
/// orchestration be unit-tested with a mock (Robolectric), while the real BDK implementation is
/// integration-tested on device/emulator.
///
/// `public` + `// SKIP @nobridge`: cross-file Kotlin resolution, no JNI bridge (only
/// `WalletManager` is the bridged entry point).
// SKIP @nobridge
public protocol WalletEngineFactory: AnyObject {
    /// Generate a brand-new wallet (random mnemonic) + its public descriptors for the network.
    /// `scriptType` is `.bip84` for new wallets (only import exposes the choice).
    func create(network: WalletNetwork, wordCount: Int, scriptType: ScriptType) throws -> WalletKeys
    /// Validate an imported mnemonic (throws `.invalidMnemonic` on bad checksum) + derive descriptors
    /// at the chosen `scriptType` (so a restored seed matches its original wallet's address kind).
    func restore(network: WalletNetwork, mnemonic: String, scriptType: ScriptType) throws -> WalletKeys
    /// Validate an imported **WIF private key** (throws `.invalidPrivateKey` on bad key / wrong
    /// network) and build the single-key PUBLIC descriptor `pkh(<pubkey>)`. The returned
    /// `WalletKeys.secret` is the WIF (persisted to the Keychain like a mnemonic). No derivation —
    /// a WIF is one key = one address (`docs/wif-import-and-sweep.md`).
    func restorePrivateKey(network: WalletNetwork, wif: String) throws -> WalletKeys
    /// The `1…` address a WIF maps to on `network`, for a live preview before import. Throws
    /// `.invalidPrivateKey` on a bad key. No secret is persisted — this is watch-only derivation.
    func previewAddress(forWIF wif: String, network: WalletNetwork) throws -> String
    /// The first receive address a seed derives at `scriptType` on `network`, for the import Advanced
    /// preview. Throws `.invalidMnemonic` on a bad phrase. No secret persisted (watch-only derivation).
    func previewAddress(forSeed mnemonic: String, scriptType: ScriptType, network: WalletNetwork) throws -> String
    /// Build the live WATCH-ONLY engine for a wallet from its PUBLIC descriptors — no private
    /// keys are held. `loadSecret` is invoked ONLY when signing a send (sign-on-demand, §7 /
    /// `docs/key-storage.md §3`); its result (a mnemonic, or a WIF for `.wif` wallets — the factory
    /// branches on `wallet.keyType`) builds a transient signer that is dropped right after.
    /// `backendKind` is `"electrum"`/`"esplora"`; `backendURL` the server; `backendProxy` an
    /// optional SOCKS5 `host:port`. (Primitives, not `WalletBackend`, so the public protocol stays
    /// off the bridge — see `WalletBackend`.)
    func engine(for wallet: ManagedWallet,
                backendKind: String, backendURL: String, backendProxy: String?,
                loadSecret: @escaping () throws -> String?) throws -> WalletEngineProtocol
    /// True if `address` is valid for `network` — correct checksum AND matching network/prefix
    /// (BDK's `Address(address:network:)` parse). Synchronous, no network: safe to call on the main
    /// actor as the user types, to validate the Send recipient early (typos + wrong-network paste).
    func isValidAddress(_ address: String, network: WalletNetwork) -> Bool
    /// Probe a backend (build the client + fetch the chain tip) so Settings can validate a custom
    /// endpoint before saving. Throws on unreachable/invalid; does network I/O (call off main).
    func testBackend(kind: String, url: String, socks5: String?) throws
    /// Purge the wallet's BDK chain-data store (the factory owns it; the manager can't reach it).
    /// Best-effort: a failed delete must not block wallet removal — the secret is gone first.
    /// Called by `WalletManager.removeWallet` so removal purges EVERY keyed artifact (Golden Rule §5).
    func purgeChainData(for walletId: String)
}

/// Deterministic factory for unit tests — no BDK. Uses the canonical 12-word test vector.
/// `public` + `// SKIP @nobridge` (cross-file Kotlin resolution; not bridged).
// SKIP @nobridge
public final class MockWalletEngineFactory: WalletEngineFactory {
    public var mnemonicToReturn: String
    /// When true, `restore` rejects as if the checksum were invalid.
    public var rejectImport = false
    /// Records the walletIds passed to `purgeChainData`, so tests can assert removal purges it.
    public private(set) var purgedChainDataIds: [String] = []

    public init(mnemonic: String = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about") {
        self.mnemonicToReturn = mnemonic
    }

    public func create(network: WalletNetwork, wordCount: Int, scriptType: ScriptType = .bip84) throws -> WalletKeys {
        WalletKeys(secret: mnemonicToReturn,
                   externalDescriptor: "wpkh(mock/0/*)",
                   internalDescriptor: "wpkh(mock/1/*)")
    }

    public func restore(network: WalletNetwork, mnemonic: String, scriptType: ScriptType = .bip84) throws -> WalletKeys {
        if rejectImport { throw WalletError.invalidMnemonic }
        return WalletKeys(secret: mnemonic,
                          externalDescriptor: "wpkh(mock/0/*)",
                          internalDescriptor: "wpkh(mock/1/*)")
    }

    /// The stubbed seed preview address (tests can override). Distinct per script type is not modeled.
    public var previewSeedAddressToReturn = "bc1qmockseedaddrxxxxxxxxxxxxxxxxxxxxxxx"

    public func previewAddress(forSeed mnemonic: String, scriptType: ScriptType, network: WalletNetwork) throws -> String {
        if rejectImport { throw WalletError.invalidMnemonic }
        return previewSeedAddressToReturn
    }

    /// When true, `restorePrivateKey`/`previewAddress` reject as if the WIF were invalid.
    public var rejectPrivateKey = false
    /// The stubbed preview address returned by `previewAddress` (tests can override).
    public var previewAddressToReturn = "1MockLegacyAddrXXXXXXXXXXXXXXXXXXXX"

    public func restorePrivateKey(network: WalletNetwork, wif: String) throws -> WalletKeys {
        if rejectPrivateKey { throw WalletError.invalidPrivateKey }
        // Single-key wallet: external == internal (one address, no change branch).
        return WalletKeys(secret: wif,
                          externalDescriptor: "pkh(mock)",
                          internalDescriptor: "pkh(mock)")
    }

    public func previewAddress(forWIF wif: String, network: WalletNetwork) throws -> String {
        if rejectPrivateKey { throw WalletError.invalidPrivateKey }
        return previewAddressToReturn
    }

    public func engine(for wallet: ManagedWallet,
                       backendKind: String, backendURL: String, backendProxy: String?,
                       loadSecret: @escaping () throws -> String?) throws -> WalletEngineProtocol {
        MockWalletEngine(network: wallet.network)
    }

    /// Records the last-tested endpoint URL; succeeds unless `failTestBackend` is set (tests).
    public private(set) var lastTestedURL: String?
    public var failTestBackend = false
    public func testBackend(kind: String, url: String, socks5: String?) throws {
        lastTestedURL = url
        if failTestBackend { throw WalletError.syncFailed }
    }

    /// Deterministic stub: an address is "valid" if non-empty and space-free. The view-model tests
    /// inject their own validator, so this only backs any direct manager-level use.
    public func isValidAddress(_ address: String, network: WalletNetwork) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains(" ")
    }

    public func purgeChainData(for walletId: String) {
        purgedChainDataIds.append(walletId)
    }
}

// The real BDK-backed factory lives in BDKWalletEngineFactory.swift (the BDK seam).

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
