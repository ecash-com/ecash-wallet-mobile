// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The real BDK-backed wallet factory — the BDK seam. Compiles natively with bdk-swift on Apple;
// transpiles to bdk-android on Android. See the bdk-swift-2.3.1-api-map memory.
//
// The ENTIRE file is `#if !SKIP_BRIDGE`: `WalletService` is a bridged transpiled module
// (`bridging: true`), so on Android the Fuse app's calls FORWARD (JNI) into this module's
// transpiled Kotlin (which holds the real bdk-android). The bridge *compile* (SKIP_BRIDGE) excludes
// all of this and uses Skip's generated forwarders — no BDK references, no duplicate symbols there.
// (Earlier this file hand-stubbed `throw .notImplemented` in the bridge pass; that stub was what
// actually ran on Android because bridging wasn't enabled.)

#if !SKIP_BRIDGE

import Foundation
#if !os(Android)
import BitcoinDevKit            // bdk-swift (Apple)
#elseif SKIP
import org.bitcoindevkit.__     // bdk-android (Kotlin)
#endif

// `public` + `// SKIP @nobridge`: `WalletManager()` constructs it cross-file (needs public for the
// transpiled Kotlin to resolve it), but it's BDK-backed so it must never reach the JNI bridge.
// SKIP @nobridge
public final class BDKWalletEngineFactory: WalletEngineFactory {
    /// Directory under which each wallet's BDK SQLite chain-data file lives (one file per
    /// `walletId`). Injectable for tests; defaults to `<applicationSupport>/chaindata`.
    private let chainDataDirectory: URL

    public init(chainDataDirectory: URL? = nil) {
        self.chainDataDirectory = chainDataDirectory
            ?? URL.applicationSupportDirectory.appendingPathComponent("chaindata", isDirectory: true)
    }

    /// Generate a brand-new wallet: random mnemonic → public BIP84 descriptors.
    public func create(network: WalletNetwork, wordCount: Int) throws -> WalletKeys {
        let mnemonic = Mnemonic(wordCount: BDKSeam.wordCount(wordCount))
        return try walletKeys(network: network, mnemonic: mnemonic)
    }

    /// Restore from a mnemonic phrase. `Mnemonic.fromString` validates the checksum/words and
    /// throws on bad input — mapped to `.invalidMnemonic` (no raw text leaks, §2).
    public func restore(network: WalletNetwork, mnemonic mnemonicPhrase: String) throws -> WalletKeys {
        let mnemonic: Mnemonic
        do {
            mnemonic = try Mnemonic.fromString(mnemonic: mnemonicPhrase)
        } catch {
            throw WalletError.invalidMnemonic
        }
        return try walletKeys(network: network, mnemonic: mnemonic)
    }

    /// Build the live WATCH-ONLY engine for a wallet. The everyday `Wallet` is built from the
    /// stored PUBLIC descriptors only — it can show balance, derive addresses, sync, and BUILD an
    /// unsigned PSBT, but it holds NO private keys. Private material materializes only inside the
    /// `signPsbt` closure, at send time (sign-on-demand, §7 / `docs/key-storage.md §3`): it loads
    /// the mnemonic, builds a TRANSIENT in-memory signer wallet from the secret descriptors, signs,
    /// and lets all of it go out of scope immediately. First open has no persisted changeset, so
    /// `Wallet.load` throws and we fall through to the network-aware constructor; later opens reload.
    public func engine(for wallet: ManagedWallet,
                       backendKind: String, backendURL: String, backendProxy: String?,
                       loadMnemonic: @escaping () throws -> String?) throws -> WalletEngineProtocol {
        let net = BDKSeam.network(wallet.network)
        let backend = WalletBackend(kindRaw: backendKind, url: backendURL, socks5: backendProxy)
        do {
            // WATCH-ONLY: build from the persisted PUBLIC descriptor strings (no secrets on the
            // everyday wallet or its on-disk chain store).
            let externalDescriptor = try Descriptor(descriptor: wallet.externalDescriptor, network: net)
            let internalDescriptor = try Descriptor(descriptor: wallet.internalDescriptor, network: net)
            let persister = try makePersister(for: wallet.id, network: wallet.network)
            // `var` (not deferred `let`): assigning in both do/catch transpiles to a reassigned
            // Kotlin `val`, which Kotlin rejects.
            var bdkWallet: Wallet
            do {
                bdkWallet = try Wallet.load(descriptor: externalDescriptor,
                                            changeDescriptor: internalDescriptor,
                                            persister: persister)
            } catch {
                bdkWallet = try Wallet(descriptor: externalDescriptor,
                                       changeDescriptor: internalDescriptor,
                                       network: net,
                                       persister: persister)
                _ = try bdkWallet.persist(persister: persister)
            }

            // SIGN-ON-DEMAND: the only place private keys exist, and only for the duration of one
            // signing. BDK derives the signing key from the PSBT's own BIP32 paths, so a fresh
            // in-memory wallet from the secret descriptors signs a PSBT the watch-only wallet built.
            let signPsbt: (Psbt) throws -> Bool = { psbt in
                guard let phrase = try loadMnemonic() else { throw WalletError.signingFailed }
                let mnemonic: Mnemonic
                do {
                    mnemonic = try Mnemonic.fromString(mnemonic: phrase)
                } catch {
                    throw WalletError.signingFailed
                }
                let secretKey = DescriptorSecretKey(network: net, mnemonic: mnemonic, password: nil)
                let extPriv = Descriptor.newBip84(secretKey: secretKey,
                                                  keychainKind: BDKSeam.externalKeychain(), network: net)
                let intPriv = Descriptor.newBip84(secretKey: secretKey,
                                                  keychainKind: BDKSeam.internalKeychain(), network: net)
                let signer = try Wallet(descriptor: extPriv, changeDescriptor: intPriv,
                                        network: net, persister: Persister.newInMemory())
                return try signer.sign(psbt: psbt, signOptions: nil)
            }

            return WalletEngine(wallet: bdkWallet, persister: persister,
                                network: wallet.network, backend: backend, signPsbt: signPsbt)
        } catch {
            // Scrub: a BDK error string can embed key material — classify, never echo (Golden Rule §2).
            throw WalletError.mapping(rawDescription: "\(error)")
        }
    }

    /// Validate a recipient address for `network` via BDK — `Address(address:network:)` checks the
    /// checksum AND the network/prefix (a `bc1…` on testnet, or `tb1…` on mainnet, fails). Sync,
    /// no network. Used to validate the Send recipient as the user types (Golden Rule §6/§7).
    public func isValidAddress(_ address: String, network: WalletNetwork) -> Bool {
        do {
            _ = try Address(address: address, network: BDKSeam.network(network))
            return true
        } catch {
            return false
        }
    }

    /// Validate a backend by building the client and fetching the chain tip. Throws `.syncFailed`
    /// on unreachable/invalid (scrubbed). Network I/O — callers run it off the main actor.
    public func testBackend(kind: String, url: String, socks5: String?) throws {
        let backend = WalletBackend(kindRaw: kind, url: url, socks5: socks5)
        do {
            switch backend.kind {
            case .electrum:
                let client = try ElectrumClient(url: backend.url, socks5: backend.socks5)
                _ = try client.blockHeadersSubscribe()
            case .esplora:
                let client = EsploraClient(url: backend.url, proxy: backend.socks5)
                _ = try client.getHeight()
            }
        } catch {
            throw WalletError.syncFailed
        }
    }

    /// Delete ALL of a wallet's BDK SQLite stores — every `(walletId × network)` file plus the
    /// legacy un-namespaced one, with `-wal`/`-shm` siblings. A wallet can hold a store per network
    /// (chain data is namespaced by network, ready for network switching — `docs/network-switching.md`),
    /// so remove-wallet must purge them all (Golden Rule §5). Best-effort.
    public func purgeChainData(for walletId: String) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: chainDataDirectory.path)) ?? []
        for name in names where name.hasPrefix("\(walletId)-") || name.hasPrefix("\(walletId).sqlite") {
            try? fm.removeItem(at: chainDataDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Helpers

    /// One SQLite file per `(walletId × network)` under `chainDataDirectory`, named
    /// `<walletId>-<network>.sqlite`. Network is in the path so the same seed on two chains never
    /// shares a store (their scriptPubKeys are identical on the testnet-class networks — mixing them
    /// would corrupt UTXO accounting; see `docs/network-switching.md`).
    ///
    /// One-time migration: wallets created before the layout change have an un-namespaced
    /// `<walletId>.sqlite`. Since each was pinned to one network, move it (and its `-wal`/`-shm`) to
    /// the network-scoped path so existing chain data survives instead of forcing a full rescan.
    private func makePersister(for walletId: String, network: WalletNetwork) throws -> Persister {
        let fm = FileManager.default
        try fm.createDirectory(at: chainDataDirectory, withIntermediateDirectories: true)
        let scoped = chainDataDirectory.appendingPathComponent("\(walletId)-\(network.rawValue).sqlite")
        let legacy = chainDataDirectory.appendingPathComponent("\(walletId).sqlite")
        if !fm.fileExists(atPath: scoped.path) && fm.fileExists(atPath: legacy.path) {
            for suffix in ["", "-wal", "-shm"] {
                let from = chainDataDirectory.appendingPathComponent("\(walletId).sqlite\(suffix)")
                let to = chainDataDirectory.appendingPathComponent("\(walletId)-\(network.rawValue).sqlite\(suffix)")
                if fm.fileExists(atPath: from.path) {
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }
        return try Persister.newSqlite(path: scoped.path)
    }

    /// Derive the PUBLIC (watch) BIP84 descriptors for both keychains from a mnemonic.
    ///
    /// Built through the SAME `Descriptor.newBip84` path the runtime engine uses, then printed
    /// via Display — which is the descriptor's PUBLIC form (account-level tpub; the secret keymap
    /// only prints via `toStringWithSecret`). FIXED 2026-06-12: this previously fed the MASTER
    /// public key to `newBip84Public` (which expects an account-level key), persisting a
    /// master-tpub descriptor whose derived addresses matched nothing the wallet actually used.
    /// Building both from one construction makes stored-vs-runtime divergence impossible.
    private func walletKeys(network: WalletNetwork, mnemonic: Mnemonic) throws -> WalletKeys {
        let net = BDKSeam.network(network)
        let secretKey = DescriptorSecretKey(network: net, mnemonic: mnemonic, password: nil)
        let external = Descriptor.newBip84(secretKey: secretKey,
                                           keychainKind: BDKSeam.externalKeychain(), network: net)
        let change = Descriptor.newBip84(secretKey: secretKey,
                                         keychainKind: BDKSeam.internalKeychain(), network: net)
        // String interpolation forces Display (`.toString()` on Kotlin) — portable across bindings.
        return WalletKeys(mnemonic: "\(mnemonic)",
                          externalDescriptor: "\(external)",
                          internalDescriptor: "\(change)")
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
