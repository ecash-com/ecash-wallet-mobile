// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Owns the set of wallets + the selected wallet, and the wallet lifecycle.
/// Build the manager first — the app is multi-wallet from day one. Orchestrates the KeyStore
/// (secret), WalletStore (public metadata), and the engine factory (BDK), keeping each wallet's
/// data isolated and namespaced by `walletId` (Golden Rule §5).
///
/// Plain class (not `@Observable`): the app's observable state holds and exposes it, so we don't
/// rely on observable-across-the-bridge behavior.
///
/// `@unchecked Sendable`: the app (a `@MainActor` `AppState`) calls `sync(walletId:)` with `await`,
/// which runs the BDK network work off the main actor — so the compiler needs `WalletManager` to be
/// `Sendable`. Wallet ops are serialized in practice (one writer — CLAUDE.md §10): mutations
/// (create/import/remove/select) and the cached `balance(_:)` run on the main actor; only the
/// network half of `sync` runs off it. The shared mutable state touched off-main is the `engines`
/// cache; full actor-isolation of the engine layer is a follow-up if we ever sync concurrently.
public final class WalletManager: @unchecked Sendable {
    private let keyStore: KeyStore
    private let walletStore: WalletStore
    private let factory: WalletEngineFactory

    public private(set) var wallets: [ManagedWallet] = []
    public private(set) var selectedWalletId: String?

    /// Live `WalletEngine`s, one per walletId, built lazily and reused so `balance`/`sync` don't
    /// re-read the mnemonic + reopen the BDK SQLite store on every call. Evicted on remove. Not
    /// bridged (the engine type is `@nobridge`); the app reaches it only through the facade below.
    private var engines: [String: WalletEngineProtocol] = [:]

    /// Designated init with injectable stores/factory (tests use mocks). Internal: the protocol
    /// types aren't part of the public/bridged surface.
    init(keyStore: KeyStore, walletStore: WalletStore, factory: WalletEngineFactory) {
        self.keyStore = keyStore
        self.walletStore = walletStore
        self.factory = factory
    }

    /// The single PUBLIC (bridged) constructor — wires the real Keychain + JSON store + BDK factory.
    /// No protocol types cross the bridge; the app just does `WalletManager()`.
    public convenience init() {
        // Inlined (no local var): Kotlin forbids a delegating self.init() referencing locals.
        self.init(keyStore: KeychainKeyStore(),
                  walletStore: (try? FileWalletStore.applicationSupport()) ?? InMemoryWalletStore(),
                  factory: BDKWalletEngineFactory())
    }

    // MARK: - Selection

    public var hasWallets: Bool { !wallets.isEmpty }

    public var selectedWallet: ManagedWallet? {
        guard let id = selectedWalletId else { return nil }
        return wallets.first { $0.id == id }
    }

    /// Load persisted wallets (call at launch). Keeps the current selection if still present,
    /// else selects the first wallet.
    public func load() throws {
        wallets = try walletStore.allWallets()
        if selectedWalletId == nil || !wallets.contains(where: { $0.id == selectedWalletId }) {
            selectedWalletId = wallets.first?.id
        }
    }

    public func select(id: String) {
        if wallets.contains(where: { $0.id == id }) {
            selectedWalletId = id
        }
    }

    // MARK: - Create / import

    /// Create a brand-new wallet on the chosen network, persist it, and select it.
    public func createWallet(label: String, network: WalletNetwork, wordCount: Int = 12) throws -> ManagedWallet {
        let keys = try factory.create(network: network, wordCount: wordCount)
        return try persistNewWallet(label: label, network: network, keys: keys)
    }

    /// Import a wallet from a mnemonic (validated by the factory; throws `.invalidMnemonic` on a
    /// bad checksum), persist it, and select it.
    public func importWallet(label: String, network: WalletNetwork, mnemonic: String) throws -> ManagedWallet {
        let keys = try factory.restore(network: network, mnemonic: mnemonic)
        return try persistNewWallet(label: label, network: network, keys: keys)
    }

    private func persistNewWallet(label: String, network: WalletNetwork, keys: WalletKeys) throws -> ManagedWallet {
        let id = UUID().uuidString
        let wallet = ManagedWallet(id: id, label: label, network: network,
                                   externalDescriptor: keys.externalDescriptor,
                                   internalDescriptor: keys.internalDescriptor,
                                   isBackedUp: false, sortIndex: wallets.count)
        // Secret first, then public metadata. Roll back the secret if metadata write fails so we
        // never strand a mnemonic with no wallet record.
        try keyStore.saveMnemonic(keys.mnemonic, walletId: id)
        do {
            try walletStore.upsertWallet(wallet)
        } catch {
            try? keyStore.deleteMnemonic(walletId: id)
            throw WalletError.persistenceFailed
        }
        wallets.append(wallet)
        selectedWalletId = id
        return wallet
    }

    // MARK: - Mutate

    public func renameWallet(id: String, to label: String) throws {
        guard let index = wallets.firstIndex(where: { $0.id == id }) else { return }
        var updated = wallets[index]
        updated.label = label
        try walletStore.upsertWallet(updated)
        wallets[index] = updated
    }

    /// Mark a wallet backed up (after the Backup verify step succeeds).
    public func setBackedUp(id: String) throws {
        guard let index = wallets.firstIndex(where: { $0.id == id }) else { return }
        var updated = wallets[index]
        updated.isBackedUp = true
        try walletStore.upsertWallet(updated)
        wallets[index] = updated
    }

    /// Remove a wallet — PURGES its mnemonic (KeyStore), its metadata (WalletStore), AND its BDK
    /// chain-data store (factory), and re-selects another wallet if the removed one was selected
    /// (Golden Rule §5 — every keyed artifact). Secret first, so a later failure can't strand it.
    public func removeWallet(id: String) throws {
        try keyStore.deleteMnemonic(walletId: id)
        try walletStore.deleteWallet(id: id)
        factory.purgeChainData(for: id)
        engines[id] = nil
        wallets.removeAll { $0.id == id }
        if selectedWalletId == id {
            selectedWalletId = wallets.first?.id
        }
    }

    /// Remove EVERY wallet — purges all mnemonics (Keychain), metadata (WalletStore), and BDK
    /// chain stores, and clears the selection (returns to the empty state). Dev/reset + a future
    /// "erase all data" Settings action. Iterates a copied id list since `removeWallet` mutates.
    public func removeAllWallets() throws {
        for id in wallets.map({ $0.id }) {
            try removeWallet(id: id)
        }
    }

    // MARK: - Access

    /// The wallet's mnemonic, for the gated Backup reveal only. Never log this.
    public func mnemonic(for id: String) throws -> String? {
        try keyStore.loadMnemonic(walletId: id)
    }

    /// Build the live `WalletEngine` for a wallet (loads its mnemonic, hands it to the factory).
    /// Internal: `WalletEngineProtocol` is not bridged; engine operations are exposed to the app
    /// through `WalletManager` facade methods (added per slice — balance/sync/send in Slice 2+).
    func engine(for wallet: ManagedWallet) throws -> WalletEngineProtocol {
        // Watch-only build: the mnemonic is NOT read here. The factory's engine derives nothing
        // secret to show balance/addresses/history; the Keychain is touched only at sign time,
        // through this closure (sign-on-demand, §7 / docs/key-storage.md §3).
        let keyStore = self.keyStore
        let walletId = wallet.id
        let backend = resolvedBackend(for: wallet.network)
        return try factory.engine(for: wallet,
                                  backendKind: backend.kind.rawValue,
                                  backendURL: backend.url,
                                  backendProxy: backend.socks5,
                                  loadMnemonic: { try keyStore.loadMnemonic(walletId: walletId) })
    }

    // MARK: - Chain backend & custom endpoints (bridged primitive surface)
    //
    // Config lives in UserDefaults (read on demand — no in-memory copy to drift); the app's
    // Settings UI drives it through these String-based methods (no `WalletBackend` on the bridge).
    // A SOCKS5 proxy is global (applies to whichever client an engine builds → Tor / `.onion`).
    // Changing any of this evicts cached engines so the next sync rebuilds. See
    // `docs/backends-and-endpoints.md`.

    private static let proxyKey = "backend.socks5"
    private func kindKey(_ n: WalletNetwork) -> String { "backend.\(n.rawValue).kind" }
    private func urlKey(_ n: WalletNetwork) -> String { "backend.\(n.rawValue).url" }
    // Remote (fetched) per-network defaults — last-known-good from the endpoints config service.
    // A SEPARATE namespace from the user override above, so it slots BELOW the user's choice and
    // ABOVE the bundled default without ever masquerading as a user override in Settings. Persisted
    // so a cold, offline launch still uses the last-known-good remote endpoint (falls back to the
    // bundled default only if the config has never been fetched). See RemoteEndpointConfig.
    private func remoteKindKey(_ n: WalletNetwork) -> String { "backend.remote.\(n.rawValue).kind" }
    private func remoteUrlKey(_ n: WalletNetwork) -> String { "backend.remote.\(n.rawValue).url" }

    private func trimmedOrNil(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// The effective backend for a network, in precedence order (highest first):
    ///   1. **user override** (Settings) — the user's explicit choice always wins;
    ///   2. **remote default** — last-known-good from the fetched endpoints config;
    ///   3. **bundled default** — the compiled `NetworkRegistry` value (offline-safe fallback).
    /// The global SOCKS5 proxy is applied on top of whichever wins. Consensus/derivation params are
    /// never involved here — only the backend URL/kind is remote-configurable (Golden Rule §1/§4).
    func resolvedBackend(for network: WalletNetwork) -> WalletBackend {
        let defaults = UserDefaults.standard
        let proxy = trimmedOrNil(defaults.string(forKey: Self.proxyKey))
        // 1. User override.
        if let url = trimmedOrNil(defaults.string(forKey: urlKey(network))),
           let kind = WalletBackend.Kind(rawValue: defaults.string(forKey: kindKey(network)) ?? "") {
            return WalletBackend(kind: kind, url: url, socks5: proxy)
        }
        // 2. Remote default (last-known-good).
        if let url = trimmedOrNil(defaults.string(forKey: remoteUrlKey(network))),
           let kind = WalletBackend.Kind(rawValue: defaults.string(forKey: remoteKindKey(network)) ?? "") {
            return WalletBackend(kind: kind, url: url, socks5: proxy)
        }
        // 3. Bundled default.
        let params = NetworkRegistry.params(for: network)
        let defaultKind = WalletBackend.Kind(rawValue: params.defaultBackendKind) ?? .electrum
        return WalletBackend(kind: defaultKind, url: params.defaultBackend, socks5: proxy)
    }

    /// Set a per-network custom endpoint. `kind` is `"electrum"`/`"esplora"`.
    public func setBackendOverride(network: WalletNetwork, kind: String, url: String) {
        let defaults = UserDefaults.standard
        defaults.set(kind, forKey: kindKey(network))
        defaults.set(url, forKey: urlKey(network))
        engines.removeAll()
    }

    /// Revert a network to its registry default endpoint.
    public func clearBackendOverride(network: WalletNetwork) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: kindKey(network))
        defaults.removeObject(forKey: urlKey(network))
        engines.removeAll()
    }

    /// Apply a **remote** per-network default from the fetched endpoints config. Precedence-wise this
    /// sits below any user override and above the bundled default (see `resolvedBackend`). `kind` must
    /// be `"electrum"`/`"esplora"` and `url` non-empty, else the call is a safe no-op (a malformed
    /// remote entry can never corrupt resolution — it just leaves the prior value in place). Engines
    /// are evicted ONLY when the value actually changes, so a routine re-fetch of unchanged config
    /// doesn't force a needless re-sync. Bridge-safe primitives (no `WalletBackend` on the JNI surface).
    public func setRemoteBackendDefault(network: WalletNetwork, kind: String, url: String) {
        guard WalletBackend.Kind(rawValue: kind) != nil, let cleanURL = trimmedOrNil(url) else { return }
        let defaults = UserDefaults.standard
        let changed = defaults.string(forKey: remoteUrlKey(network)) != cleanURL
            || defaults.string(forKey: remoteKindKey(network)) != kind
        guard changed else { return }
        defaults.set(kind, forKey: remoteKindKey(network))
        defaults.set(cleanURL, forKey: remoteUrlKey(network))
        engines.removeAll()   // next sync rebuilds against the new endpoint
    }

    /// Clear all remote defaults (revert every network to user-override-or-bundled). Not needed in
    /// normal operation — exposed for a full reset / tests.
    public func clearRemoteBackendDefaults() {
        let defaults = UserDefaults.standard
        for network in WalletNetwork.allCases {
            defaults.removeObject(forKey: remoteKindKey(network))
            defaults.removeObject(forKey: remoteUrlKey(network))
        }
        engines.removeAll()
    }

    /// Set (or clear, with nil/empty) the global SOCKS5 proxy `host:port`.
    public func setProxy(_ socks5: String?) {
        let defaults = UserDefaults.standard
        if let value = trimmedOrNil(socks5) {
            defaults.set(value, forKey: Self.proxyKey)
        } else {
            defaults.removeObject(forKey: Self.proxyKey)
        }
        engines.removeAll()
    }

    // Getters for the Settings UI:
    public func backendKind(for network: WalletNetwork) -> String { resolvedBackend(for: network).kind.rawValue }
    public func backendURL(for network: WalletNetwork) -> String { resolvedBackend(for: network).url }
    public func defaultBackendURL(for network: WalletNetwork) -> String { NetworkRegistry.params(for: network).defaultBackend }
    public func hasBackendOverride(for network: WalletNetwork) -> Bool {
        trimmedOrNil(UserDefaults.standard.string(forKey: urlKey(network))) != nil
    }
    public func proxyValue() -> String? { trimmedOrNil(UserDefaults.standard.string(forKey: Self.proxyKey)) }

    /// Validate a candidate backend (build client + fetch tip). Throws on failure. Network I/O —
    /// `async` so the call site awaits it off the main actor.
    public func testBackend(kind: String, url: String, socks5: String?) async throws {
        try factory.testBackend(kind: kind, url: url, socks5: trimmedOrNil(socks5))
    }

    /// Validate a recipient address for a network (checksum + network/prefix), via BDK. Sync, no I/O
    /// — safe to call as the user types. See `WalletEngineFactory.isValidAddress`.
    public func isValidAddress(_ address: String, network: WalletNetwork) -> Bool {
        factory.isValidAddress(address, network: network)
    }

    /// Get-or-build the cached live engine for a walletId (see `engines`).
    private func liveEngine(walletId: String) throws -> WalletEngineProtocol {
        if let cached = engines[walletId] { return cached }
        guard let wallet = wallets.first(where: { $0.id == walletId }) else {
            throw WalletError.persistenceFailed
        }
        let engine = try engine(for: wallet)
        engines[walletId] = engine
        return engine
    }

    // MARK: - Engine facade (bridged surface for the app)
    //
    // The app can't touch `WalletEngineProtocol` (it's `@nobridge`), so balance/sync are exposed
    // here as `WalletManager` methods returning bridge-safe `Amount`. Send/receive land the same way.

    /// The wallet's CACHED balance — reads BDK's persisted chain data, no network. Fast; safe on
    /// the main actor. Returns `.zero` for a wallet with no persisted data yet.
    public func balance(walletId: String) throws -> Amount {
        try liveEngine(walletId: walletId).balance()
    }

    /// Not-yet-spendable balance (incoming 0-conf + immature) — shown separately from the spendable
    /// `balance`. Cached read, no network. See README "Spendable balance".
    public func pendingBalance(walletId: String) throws -> Amount {
        try liveEngine(walletId: walletId).pendingBalance()
    }

    /// Sync the wallet against its network backend (Electrum full scan → persist), then return the
    /// updated balance. Does network I/O — callers MUST invoke this off the main actor (Android
    /// throws `NetworkOnMainThreadException` otherwise). `async` so the call site can `await` it.
    public func sync(walletId: String) async throws -> Amount {
        let engine = try liveEngine(walletId: walletId)
        try await engine.sync()
        return try engine.balance()
    }

    /// Reveal the wallet's next external (receive) address and persist the advanced derivation
    /// index, so an address is never handed out twice. Local only (no network) — safe on the
    /// main actor. Each call advances by one — use for an explicit "New address" action only.
    public func nextReceiveAddress(walletId: String) throws -> AddressInfo {
        try liveEngine(walletId: walletId).nextReceiveAddress()
    }

    /// The lowest revealed-but-unused receive address (reveals one only if none exists) — the
    /// Receive screen's default, so opening the screen repeatedly doesn't burn index space.
    public func nextUnusedAddress(walletId: String) throws -> AddressInfo {
        try liveEngine(walletId: walletId).nextUnusedAddress()
    }

    /// The wallet's transactions from BDK's persisted chain data (no network) — safe on the main
    /// actor. Unordered; the app sorts for display. Refreshed by `sync(walletId:)`.
    public func transactions(walletId: String) throws -> [WalletTx] {
        try liveEngine(walletId: walletId).transactions()
    }

    /// Build → sign → broadcast a payment from this wallet (BDK does coin selection, change, and
    /// fee math — Golden Rule §1). Broadcast is network I/O — callers MUST invoke this off the
    /// main actor (`async`, same pattern as `sync`). Returns the optimistic pending tx for the UI.
    /// Throws typed `WalletError`s: `.invalidAddress`, `.insufficientFunds`, `.dustAmount`,
    /// `.signingFailed`, `.broadcastFailed` — never raw BDK errors (§10).
    public func send(walletId: String, to address: String,
                     amount: Amount, feeRate: FeeRate) async throws -> WalletTx {
        let engine = try liveEngine(walletId: walletId)
        return try engine.send(to: address, amount: amount, feeRate: feeRate)
    }

    /// Publish a CoinNews (or any) `OP_RETURN` message. The payload crosses the bridge as a hex
    /// string (bridge-safe) and is decoded to bytes here; the app builds it with `CoinNewsCodec`.
    /// Funds the fee from spendable coins, signs, broadcasts. Returns the optimistic pending tx.
    public func publishOpReturn(walletId: String, payloadHex: String,
                                feeRate: FeeRate) async throws -> WalletTx {
        guard let data = Self.dataFromHex(payloadHex) else {
            throw WalletError.mapping(rawDescription: "bad payload hex")
        }
        let engine = try liveEngine(walletId: walletId)
        return try engine.publishData(data, feeRate: feeRate)
    }

    /// Publish a CoinNews **Vote** (§8) against the target Item, identified by its **ItemID** (the
    /// 24-hex `item_id_hex` the indexer returns — that 12-byte id IS the vote's `target_id`; the txid
    /// is neither needed nor recoverable). Signs with the wallet's CoinNews identity key (BIP-340),
    /// assembles the 111-byte message, broadcasts as `OP_RETURN`. `upvote == false` → downvote.
    public func publishVote(walletId: String, targetIdHex: String,
                            upvote: Bool, feeRate: FeeRate) async throws -> WalletTx {
        let identity = try coinNewsIdentityKey(walletId: walletId)
        guard let targetId = Self.dataFromHex(targetIdHex), targetId.count == 12 else {
            throw WalletError.mapping(rawDescription: "invalid target id")
        }
        let payload = try CoinNewsMessage.signedVote(targetId: targetId, upvote: upvote,
                                                     identityPrivateKey: identity, auxRand: Self.zeroAux)
        let engine = try liveEngine(walletId: walletId)
        return try engine.publishData(payload, feeRate: feeRate)
    }

    /// Publish a CoinNews **Comment** (§7) replying to the parent Item/Comment by its **ItemID**
    /// (`parentIdHex`), with a text `body`. Signs (BIP-340) + broadcasts as an `OP_RETURN`.
    public func publishComment(walletId: String, parentIdHex: String,
                               body: String, feeRate: FeeRate) async throws -> WalletTx {
        let identity = try coinNewsIdentityKey(walletId: walletId)
        guard let parentId = Self.dataFromHex(parentIdHex), parentId.count == 12 else {
            throw WalletError.mapping(rawDescription: "invalid parent id")
        }
        let payload = try CoinNewsMessage.signedComment(parentId: parentId, body: body,
                                                        identityPrivateKey: identity, auxRand: Self.zeroAux)
        let engine = try liveEngine(walletId: walletId)
        return try engine.publishData(payload, feeRate: feeRate)
    }

    /// Derive the wallet's CoinNews identity private key on demand (never persisted — Golden Rule §2).
    private func coinNewsIdentityKey(walletId: String) throws -> Data {
        guard let wallet = wallets.first(where: { $0.id == walletId }),
              let phrase = try keyStore.loadMnemonic(walletId: walletId) else {
            throw WalletError.signingFailed
        }
        return try CoinNewsIdentity.privateKey(mnemonicPhrase: phrase, network: wallet.network)
    }

    /// BIP-340 aux randomness. Zero is valid + deterministic; TODO: secure-random for fault-attack
    /// protection (defense-in-depth — the signed data is public, so determinism leaks nothing here).
    private static let zeroAux = Data([UInt8](repeating: UInt8(0), count: 32))

    // Iterate the ASCII (UTF-8) bytes + integer-range matching, so this transpiles cleanly to Kotlin
    // (a `Character` switch / `Array(String)` does not).
    private static func dataFromHex(_ hex: String) -> Data? {
        let ascii = Array(hex.utf8)
        guard ascii.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var i = 0
        while i < ascii.count {
            guard let hi = hexNibble(ascii[i]), let lo = hexNibble(ascii[i + 1]) else { return nil }
            bytes.append(UInt8(hi * 16 + lo))
            i += 2
        }
        return Data(bytes)
    }

    private static func hexNibble(_ b: UInt8) -> Int? {
        let v = Int(b)
        if v >= 48 && v <= 57 { return v - 48 }    // '0'–'9'
        if v >= 97 && v <= 102 { return v - 87 }   // 'a'–'f'
        if v >= 65 && v <= 70 { return v - 55 }    // 'A'–'F'
        return nil
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
