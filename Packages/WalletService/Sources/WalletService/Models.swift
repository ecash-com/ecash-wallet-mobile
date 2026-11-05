// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

// MARK: - Money
//
// All monetary values are satoshis as SIGNED Int64 (Bitcoin Core's own CAmount convention).
// NEVER use Swift `Int` for sat math: Kotlin's `Int` is 32-bit and intermediate arithmetic
// silently overflows on Android. Int64 transpiles to Kotlin `Long` (64-bit) and is safe.
// NOT UInt64: unsigned types become Kotlin inline value classes whose property getters are
// JVM-name-mangled, which crashes Skip's generated JNI bridge on first access from the Fuse
// app on Android (see CLAUDE.md §5). Total supply is 2.1e15 sats; Int64 holds 9.2e18.

/// A monetary amount in satoshis. The display unit (BTC vs eCash) is resolved from the
/// owning wallet's network, never stored here. Format only at the view layer.
public struct Amount: Equatable, Comparable, Hashable, Sendable {
    public let sats: Int64

    public init(sats: Int64) {
        self.sats = sats
    }

    public static let zero = Amount(sats: 0)

    /// 1 BTC / 1 eCash = 100_000_000 sats.
    public static let satsPerCoin: Int64 = 100_000_000

    public func adding(_ other: Amount) -> Amount {
        Amount(sats: sats + other.sats)
    }

    /// Returns nil on underflow rather than trapping.
    public func subtracting(_ other: Amount) -> Amount? {
        sats >= other.sats ? Amount(sats: sats - other.sats) : nil
    }

    public static func < (lhs: Amount, rhs: Amount) -> Bool {
        lhs.sats < rhs.sats
    }

    /// The most that can be sent given a balance and the fee it would cost: `balance − fee`,
    /// never negative (`.zero` if the fee meets or exceeds the balance).
    public static func maxSpend(balance: Amount, fee: Amount) -> Amount {
        balance.subtracting(fee) ?? .zero
    }

    /// Full 8-decimal coin string, no unit — e.g. 84_210_000 sats → `"0.84210000"`.
    /// Integer math only, never float (Golden Rule §6). The unit label (BTC / eCash) is
    /// appended at the view layer from the wallet's network, never here.
    public func formattedCoin() -> String {
        let whole = sats / Amount.satsPerCoin
        let frac = sats % Amount.satsPerCoin
        // Left-pad the fractional sats to 8 digits. (frac < 100_000_000, so 1–8 digits.)
        var fracDigits = "\(frac)"
        while fracDigits.count < 8 {
            fracDigits = "0" + fracDigits
        }
        return "\(whole).\(fracDigits)"
    }

    /// Parses a coin-denominated decimal string (e.g. `"0.001"`, `"1"`, `"21000000"`) into an
    /// `Amount`. Integer math only — no float. Returns nil for malformed input, a sign, or more
    /// than 8 decimal places. Round-trips with `formattedCoin()`.
    public static func fromCoin(_ string: String) -> Amount? {
        if string.isEmpty { return nil }
        let parts = string.components(separatedBy: ".")
        if parts.count > 2 { return nil } // more than one decimal point
        let wholeStr = parts[0]
        let fracStr = parts.count == 2 ? parts[1] : ""
        if fracStr.count > 8 { return nil } // sub-satoshi precision
        if wholeStr.count > 10 { return nil } // overflow guard: < 1e10 coins (×1e8 sats fits Int64)
        // Parse through UInt64 ON PURPOSE: it rejects signs ("-1"/"+1") and non-digits in one
        // step, which Int64's parser would accept. The 10-digit guard above makes the
        // conversion to Int64 safe.
        guard let whole = UInt64(wholeStr.isEmpty ? "0" : wholeStr) else { return nil }
        // Right-pad the fractional digits to 8, then parse (also validates digits-only).
        var fracDigits = fracStr
        while fracDigits.count < 8 {
            fracDigits = fracDigits + "0"
        }
        guard let frac = UInt64(fracDigits) else { return nil }
        return Amount(sats: Int64(whole) * Amount.satsPerCoin + Int64(frac))
    }
}

/// A fee rate in satoshis per virtual byte. BDK consumes this when building a tx.
/// Signed Int64 (not UInt64) — bridged properties must avoid unsigned types (see Amount).
public struct FeeRate: Equatable, Hashable, Sendable {
    public let satPerVByte: Int64
    public init(satPerVByte: Int64) {
        self.satPerVByte = satPerVByte
    }
}

// MARK: - Network
//
// Network is a per-wallet property (Golden Rule §4). Treat this enum as non-exhaustive
// in spirit: adding eCash later should be a NetworkRegistry entry + params, not a refactor.

/// The network a wallet is pinned to at creation. Resolved through `NetworkRegistry`
/// for all chain params, coin-type, backend, explorer, address HRP, and unit label.
public enum WalletNetwork: String, Equatable, Hashable, Sendable, CaseIterable {
    case bitcoin
    /// L2L dev network; first-class in BDK.
    case signet
    /// **Alphanet — RETIRED 2026-10-26.** The first eCash test fork (after the drynet dry runs).
    /// Not in `selectable` and no longer in the remote config; the case exists only because its
    /// rawValue `"ecash"` is persisted in existing wallets' metadata and backend-override keys, so
    /// those wallets keep loading. Do NOT read this case as "the real eCash" — that is
    /// `.ecashMainnet`; the remote config's id `ecash` maps THERE, not here (see
    /// `RemoteEndpointConfig.RemoteNetwork.walletNetwork(forId:)`). Byte-identical to Bitcoin
    /// (`bc` HRP, coin-type `0'`, BDK `Network.bitcoin`), unit **ECX**.
    case ecash
    /// The eCash **betanet** — the successor chain to alphanet, running alongside it for a while
    /// before it takes over (and before the real eCash mainnet after that). Same shape as `.ecash`
    /// in every respect that matters to derivation: byte-identical to Bitcoin, mainnet `bc` HRP,
    /// coin-type `0'`, BDK `Network.bitcoin`, unit **ECX** — separated from alphanet only by its
    /// backend and its fork height (alphanet 963_648, betanet 967_680) and, at the P2P layer, by a
    /// distinct network magic (`eca5a104` vs `eca5b104`).
    ///
    /// **One seed therefore derives IDENTICAL addresses on `.ecash` and `.ecashBeta`** — the same
    /// property the testnet-class networks have via coin-type `1'`. The network chip is the only
    /// thing telling them apart (Golden Rule §6), which is why `NetworkChipStyle` gives betanet its
    /// own colour rather than reusing eCash's.
    ///
    /// **Naming, deliberately:** the rawValue `"ecash"` above is persisted in the wallet store and
    /// enforced by `check_network`, and it currently means *alphanet* — renaming it would orphan
    /// every existing eCash wallet. So the code keeps the awkward name and the **user-facing name
    /// comes from the remote config's `display_name`** ("Alphanet" / "Betanet"), which is also how
    /// the real eCash mainnet will eventually be labelled without a migration.
    case ecashBeta
    /// The **real eCash mainnet** — the fork of Bitcoin at block 973,728 that holds real ECX
    /// (github.com/ecash-com/bitcoin, `consensus.EcashHeight`). Same derivation shape as the test
    /// forks: byte-identical to Bitcoin, mainnet `bc` HRP, coin-type `0'`, BDK `Network.bitcoin`, unit
    /// **ECX** — so one seed derives the SAME addresses here as on alphanet, betanet and Bitcoin. What
    /// differs is consensus-level and compiled: its replay-protection marker is `499_999_998` (the test
    /// forks use `499_999_999`), its fork height, and OP_DRIVECHAIN = NOP8.
    ///
    /// **Real money.** `isMainnet` is true, so it gets Bitcoin's extra send confirmation and warnings.
    ///
    /// **Gated on the remote config, not a release** (`EcashMainnetLaunch`): the case is compiled in
    /// ahead of the fork, but it is NOT offered in any picker until drivechain.dev/config publishes the
    /// `ecash` entry (published 2026-10-26), and it does NOT become the default eCash network until the chain is
    /// observed past the entry's `fork_height`. Betanet keeps running alongside it either way — its
    /// case is never repurposed (a wallet's network is persisted by rawValue).
    case ecashMainnet
    /// The **Thunder** sidechain of eCash (LayerTwo-Labs/thunder-rust). NOT a BDK/secp256k1 chain —
    /// ed25519 keys, BLAKE3 base58 addresses, a Thunder-node RPC backend. Routed to the Fuse-native
    /// `ThunderService` (never the BDK engine); the `coinType`/`addressHRP` in its registry entry are
    /// unused fillers. Its rawValue `"thunder"` is persisted — don't rename the case.
    case thunder

    /// Networks offered in the create/import picker (`NetworkSelector`) — distinct from `allCases`
    /// (which the backend/registry loops still walk for every case). Also the copy-to-network
    /// targets (`WalletManager.copyTargets`). Settings → Network lists these PLUS any network an
    /// existing wallet is on, so a retired chain's endpoint stays editable for the wallets that
    /// remain on it.
    ///
    /// **Retiring a network = remove it from this list, keep the case.** The rawValue is persisted in
    /// existing wallets, which keep loading, syncing and sending; nobody can create a new one.
    /// Retired so far: alphanet (`.ecash`, 2026-10-26), **betanet (`.ecashBeta`) and Thunder
    /// betanet (`.thunder`) (2026-10-30, Jake)** — with the real fork live, the test generations
    /// are no longer offered for new wallets or imports.
    ///
    /// **eCash mainnet is listed FIRST when `EcashMainnetLaunch.isOffered`** — compiled on since 1.4.6 build 44;
    /// before that only once the remote config had published it (and a launch whose first fetch
    /// failed showed no mainnet until a later resume — the Android 1.4.6 report).
    public static var selectable: [WalletNetwork] {
        // Order is the picker order: the real eCash fork first (also the default — `currentEcash`),
        // then Bitcoin, then L2L Signet. Betanet and Thunder betanet left here 2026-10-30; to bring
        // a Thunder mainnet back, append `.thunder` once `NetworkRegistry` points it at mainnet.
        var out: [WalletNetwork] = []
        if EcashMainnetLaunch.isOffered {
            out.append(.ecashMainnet)
        }
        out.append(.bitcoin)
        out.append(.signet)
        return out
    }

    /// **The eCash chain the app currently points at** for new wallets and imports. One place so
    /// "which eCash is live" is a single rule, not a hunt through defaults. NOT used by the investor
    /// claim since 2026-10-29: a claim follows the selected wallet's eCash chain, else mainnet
    /// (`ClaimNetwork` in the app).
    ///
    /// **The real fork, `.ecashMainnet`, unconditionally** (Jake, 2026-10-29, 1.4.6 build 44 — hours
    /// before block 973,728). Until then this was betanet until the chain had been observed past the
    /// fork (`EcashMainnetLaunch.isDefault`); that latch still records whether the fork has been seen
    /// but no longer steers anything. Pre-fork the "mainnet" chain is still Bitcoin, so for the few
    /// hours this ships ahead of the block a new wallet here sees Bitcoin's chain under the ECX label
    /// and any send is non-final (compiled replay nLockTime) — it fails loud, nothing moves. Existing
    /// wallets are unaffected: a wallet's network is fixed at creation and persisted, so this only
    /// steers NEW ones (and the claim has its own rule — `ClaimNetwork` in the app).
    public static var currentEcash: WalletNetwork { .ecashMainnet }

    /// Whether coin-splitting applies to this network — i.e. it is a Bitcoin fork whose pre-fork
    /// UTXOs are shared with Bitcoin and therefore need separating (`SplitSummary.classify`,
    /// `NetworkRegistry.forkHeight`).
    ///
    /// **A property rather than scattered `== .ecash` checks.** Those checks are what silently broke
    /// split-coins on betanet when it was added (2026-09-17 → fixed 2026-09-21): the fork height was
    /// wired up correctly and then thrown away by six equality comparisons the compiler could not
    /// flag. The `switch` below is exhaustive on purpose, so the next fork chain added won't compile
    /// until someone decides this — the same protection every other per-network capability has.
    public var supportsCoinSplit: Bool {
        switch self {
        case .ecash, .ecashBeta, .ecashMainnet: return true
        case .bitcoin, .signet, .thunder: return false
        }
    }

    /// Whether one secret derives the **same keys and addresses** on this network and `other` — the
    /// test for copying a wallet across networks (`docs/copy-wallet-to-network.md`). Bitcoin and every
    /// eCash generation share Bitcoin's parameters (coin-type `0'`, `bc` HRP, mainnet key formats), so
    /// a copy there is the same wallet. L2L Signet is coin-type `1'` (different addresses), and Thunder
    /// is ed25519 — a different key system — so each stands alone.
    public func sharesKeys(with other: WalletNetwork) -> Bool {
        guard let mine = keyFamily, let theirs = other.keyFamily else { return false }
        return mine == theirs
    }

    /// The group of networks whose keys are interchangeable, or nil for a network that shares with
    /// none. Exhaustive on purpose (see `supportsCoinSplit`): a new network won't compile until
    /// someone decides whether a copied wallet there would really be the same wallet.
    public var keyFamily: Int? {
        switch self {
        case .bitcoin, .ecash, .ecashBeta, .ecashMainnet: return 0   // coin-type 0', `bc` addresses
        case .signet: return nil                      // coin-type 1' — only itself
        case .thunder: return nil                     // ed25519, not BDK
        }
    }

    /// The mainchain this sidechain settles to, or `nil` for a mainchain itself. The network
    /// switcher nests sidechains under their parent (`docs/seed-container-model.md §3.1`, decided
    /// 2026-11-04): a wallet viewing eCash sees eCash's sidechains, never another chain's. Exhaustive
    /// on purpose, like `supportsCoinSplit`: the next chain added won't compile until someone says
    /// where it belongs.
    public var parentChain: WalletNetwork? {
        switch self {
        // The registry's Thunder entry is Thunder BETANET (`seed.beta.ecash.eu.com`), so its parent
        // is eCash betanet. A Thunder on the real fork gets its own case with `.ecashMainnet` here.
        case .thunder: return .ecashBeta
        case .bitcoin, .signet, .ecash, .ecashBeta, .ecashMainnet: return nil
        }
    }

    public var isSidechain: Bool { parentChain != nil }

    /// The sidechains that settle to `mainchain`, in declaration order. Empty for Bitcoin.
    public static func sidechains(of mainchain: WalletNetwork) -> [WalletNetwork] {
        WalletNetwork.allCases.filter { $0.parentChain == mainchain }
    }

    /// **Real money.** True for Bitcoin mainnet and the real eCash mainnet; drives the extra send
    /// confirmation and the real-money warnings (Golden Rule §6). `.ecash`/`.ecashBeta` are **test**
    /// chains that nonetheless use mainnet-style `bc` addresses, so they stay false here (own chip,
    /// no real-money warnings) even though their addresses look identical to real Bitcoin — the chip
    /// is the only thing distinguishing them. Exhaustive so the next chain decides this explicitly.
    public var isMainnet: Bool {
        switch self {
        case .bitcoin, .ecashMainnet: return true
        case .signet, .ecash, .ecashBeta, .thunder: return false
        }
    }
}

/// How a wallet's secret is expressed — drives how the engine derives descriptors and signs.
/// `.mnemonic` = an HD seed (BIP84 templates, full derivation tree). `.wif` = a single legacy
/// private key imported as a **one-address** wallet (`pkh(<key>)`, no derivation — the key IS the
/// address; see `docs/wif-import-and-sweep.md`). Existing wallets predate this field and decode as
/// `.mnemonic` (the default), so persistence stays backward-compatible.
public enum WalletKeyType: String, Equatable, Hashable, Sendable, CaseIterable {
    case mnemonic
    case wif
}

/// The BIP script type (address kind) a mnemonic wallet derives — chosen on import so a user
/// restoring a seed from another wallet can match the derivation their coins actually live at
/// (recovery-correctness for the eCash airdrop; `docs/custom-derivation-path-import.md`). Each maps
/// to a BIP purpose + a BDK descriptor template. `.bip84` (native segwit) is the default and
/// reproduces the app's original behavior, so existing wallets decode as `.bip84` (back-compat).
public enum ScriptType: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case bip44   // legacy P2PKH        m/44'/…   → 1…
    case bip49   // nested segwit       m/49'/…   → 3…
    case bip84   // native segwit       m/84'/…   → bc1q…   (default)
    case bip86   // taproot             m/86'/…   → bc1p…

    /// The BIP-standard purpose index for this script type (44/49/84/86).
    public var purpose: Int32 {
        switch self {
        case .bip44: return Int32(44)
        case .bip49: return Int32(49)
        case .bip84: return Int32(84)
        case .bip86: return Int32(86)
        }
    }

    /// The script types offered when **creating** a wallet: native segwit and taproot only.
    ///
    /// Legacy (`bip44`) and nested segwit (`bip49`) are deliberately absent. A fresh wallet has no
    /// coins sitting at `1…` or `3…` addresses, so making one there buys nothing and costs something:
    /// larger inputs and higher fees for legacy, and for nested segwit the extra redeem-script
    /// overhead that only ever existed to get segwit past wallets which couldn't parse `bc1`.
    ///
    /// Both remain available on **import**, which is where they are actually needed — someone
    /// recovering an old wallet must be able to match the address kind their coins live at. Same
    /// asymmetry as `WalletNetwork.selectable`: what you may create is narrower than what you may hold.
    ///
    /// Ordered by preference, so the first entry is the sensible default.
    public static let creatable: [ScriptType] = [.bip84, .bip86]

    /// Short human label for UI (wallet detail / import picker).
    public var displayName: String {
        switch self {
        case .bip44: return "Legacy"
        case .bip49: return "Nested SegWit"
        case .bip84: return "Native SegWit"
        case .bip86: return "Taproot"
        }
    }
}

// MARK: - Wallet & chain value types

/// One account of a wallet: the keys ONE seed derives for one `(network, scriptType,
/// accountIndex)`, plus where that account's BDK chain data lives. A wallet (= a seed) holds one
/// or more of these and the user switches between them (`docs/seed-container-model.md §3`). Public
/// descriptors only (Golden Rule §5). Bridged — signed integer fields, no `Date` (CLAUDE.md §5).
public struct WalletAccount: Identifiable, Equatable, Hashable, Sendable {
    /// `"<network>-<scriptType>-<accountIndex>"` (`accountId(...)`) — unique within its wallet.
    public let id: String
    public let network: WalletNetwork
    public let scriptType: ScriptType
    /// The BIP account level (`…/account'`). `0` for every wallet today.
    public let accountIndex: Int32
    /// Public (xpub-based) descriptors — never the private variants. `""` for a sidechain account
    /// (Thunder derives outside BDK); for a `.wif` wallet the single-key `pkh(<pubkey>)` on both.
    public let externalDescriptor: String
    public let internalDescriptor: String
    /// Basename of this account's BDK SQLite store in the chain-data directory. Explicit, so a
    /// migrated account keeps the file it already has and no naming heuristic ever decides where
    /// chain data lives (invariants I3/I5). A pre-container record's one account uses
    /// `legacyStoreName`; an account added later uses `storeName(walletId:…)`.
    public let storeName: String

    public init(id: String, network: WalletNetwork, scriptType: ScriptType, accountIndex: Int32,
                externalDescriptor: String, internalDescriptor: String, storeName: String) {
        self.id = id
        self.network = network
        self.scriptType = scriptType
        self.accountIndex = accountIndex
        self.externalDescriptor = externalDescriptor
        self.internalDescriptor = internalDescriptor
        self.storeName = storeName
    }

    /// Convenience: the id is derived from the triple.
    public init(network: WalletNetwork, scriptType: ScriptType, accountIndex: Int32,
                externalDescriptor: String, internalDescriptor: String, storeName: String) {
        self.init(id: WalletAccount.accountId(network: network, scriptType: scriptType, accountIndex: accountIndex),
                  network: network, scriptType: scriptType, accountIndex: accountIndex,
                  externalDescriptor: externalDescriptor, internalDescriptor: internalDescriptor,
                  storeName: storeName)
    }

    public static func accountId(network: WalletNetwork, scriptType: ScriptType, accountIndex: Int32) -> String {
        "\(network.rawValue)-\(scriptType.rawValue)-\(accountIndex)"
    }

    /// `<walletId>-<network>.sqlite` — the one store a pre-container wallet has
    /// (`BDKWalletEngineFactory.makePersister`). A migrated record keeps exactly this.
    public static func legacyStoreName(walletId: String, network: WalletNetwork) -> String {
        "\(walletId)-\(network.rawValue).sqlite"
    }

    /// `<walletId>-<network>-<scriptType>-<acct>.sqlite` — the store of an account added to a wallet.
    public static func storeName(walletId: String, network: WalletNetwork,
                                 scriptType: ScriptType, accountIndex: Int32) -> String {
        "\(walletId)-\(network.rawValue)-\(scriptType.rawValue)-\(accountIndex).sqlite"
    }

    /// The full BIP32 path of one of this account's keys, e.g. `m/84'/1'/0'/0/5` — read from the key
    /// origin in its (public) descriptor, so it's the path the account really derives at (script
    /// type, coin type and account included), not a reconstruction. `nil` when the descriptor has
    /// no key origin (a single-key `.wif` account, a sidechain account).
    public func derivationPath(isChange: Bool, index: Int32) -> String? {
        guard let origin = ManagedWallet.keyOriginPath(isChange ? internalDescriptor : externalDescriptor) else {
            return nil
        }
        return "\(origin)/\(isChange ? 1 : 0)/\(index)"
    }

    /// The BIP32 master fingerprint from the descriptor's key origin — `wpkh([d34db33f/84'/0'/0']…)`
    /// → `"d34db33f"`. The same seed yields the same fingerprint on every coin-type and script type,
    /// which is how the seed-container migration recognises copies of one seed WITHOUT reading a
    /// mnemonic. `nil` without an origin (WIF, sidechain) or if it isn't 8 hex digits.
    public var masterFingerprint: String? {
        ManagedWallet.masterFingerprint(externalDescriptor)
    }
}

/// Metadata describing one managed wallet — **a seed** (or one WIF key), holding one or more
/// `WalletAccount`s and the one currently selected (`docs/seed-container-model.md §3`). Contains
/// NO private key material (Golden Rule §5) — the mnemonic lives in the Keychain keyed by `id`.
///
/// The pre-container shape (one record = one seed on one network) is still constructible through
/// the `network:` initializer, which builds a one-account wallet; `network`, `externalDescriptor`,
/// `internalDescriptor`, `scriptType` and `accountIndex` read through to the **selected account**
/// so existing callers keep working. Phase 1 step 5 moves them to `selectedAccount.…` explicitly.
public struct ManagedWallet: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var label: String
    /// Whether this wallet is a mnemonic (HD) wallet or a single legacy private key (`.wif`).
    /// Lets the engine pick the right construction/signing path. Defaults to `.mnemonic`.
    public let keyType: WalletKeyType
    public var isBackedUp: Bool
    public var sortIndex: Int
    /// The account the wallet is currently viewed on. Remembered per wallet; changed ONLY by an
    /// explicit switch in the UI, never implicitly (invariant I8).
    public var selectedAccountId: String
    /// Never empty — the initializers guarantee at least one account.
    public var accounts: [WalletAccount]
    /// Legacy record ids the seed-container migration folded into this wallet (its own id
    /// excluded). Report/diagnostics only.
    public let mergedFrom: [String]
    /// Keychain entries those merged records left behind. They hold the SAME phrase as this
    /// wallet's own entry. The migration never deletes them (invariant I1); remove-wallet does.
    public let orphanKeychainIds: [String]

    /// The container initializer. `accounts` must not be empty.
    public init(id: String, label: String, keyType: WalletKeyType, isBackedUp: Bool, sortIndex: Int,
                selectedAccountId: String, accounts: [WalletAccount],
                mergedFrom: [String] = [], orphanKeychainIds: [String] = []) {
        precondition(!accounts.isEmpty, "a wallet needs at least one account")
        self.id = id
        self.label = label
        self.keyType = keyType
        self.isBackedUp = isBackedUp
        self.sortIndex = sortIndex
        self.selectedAccountId = selectedAccountId
        self.accounts = accounts
        self.mergedFrom = mergedFrom
        self.orphanKeychainIds = orphanKeychainIds
    }

    /// The pre-container shape: one seed on one network. Builds a wallet with exactly one account
    /// whose store is the legacy `<id>-<network>.sqlite`. Used by create/import today and by the
    /// legacy `wallets.json` decoder; existing wallets decode through this unchanged.
    public init(id: String, label: String, network: WalletNetwork,
                externalDescriptor: String, internalDescriptor: String,
                keyType: WalletKeyType = .mnemonic,
                scriptType: ScriptType = .bip84, accountIndex: Int32 = 0,
                isBackedUp: Bool = false, sortIndex: Int = 0) {
        // Assigns directly rather than delegating to the container init: Kotlin can't pass a local
        // (the account) into a `this(...)` constructor call, so Skip rejects the delegation.
        let account = WalletAccount(network: network, scriptType: scriptType, accountIndex: accountIndex,
                                    externalDescriptor: externalDescriptor,
                                    internalDescriptor: internalDescriptor,
                                    storeName: WalletAccount.legacyStoreName(walletId: id, network: network))
        self.id = id
        self.label = label
        self.keyType = keyType
        self.isBackedUp = isBackedUp
        self.sortIndex = sortIndex
        self.selectedAccountId = account.id
        self.accounts = [account]
        self.mergedFrom = []
        self.orphanKeychainIds = []
    }

    /// The account `selectedAccountId` names, falling back to the first account if the id is stale
    /// (never crashes the money surfaces over a bad selection; the chip still shows what's read).
    public var selectedAccount: WalletAccount {
        accounts.first { $0.id == selectedAccountId } ?? accounts[0]
    }

    public func account(id: String) -> WalletAccount? {
        accounts.first { $0.id == id }
    }

    // MARK: Selected-account read-throughs (compat shims — see the type comment)

    public var network: WalletNetwork { selectedAccount.network }
    public var externalDescriptor: String { selectedAccount.externalDescriptor }
    public var internalDescriptor: String { selectedAccount.internalDescriptor }
    public var scriptType: ScriptType { selectedAccount.scriptType }
    public var accountIndex: Int32 { selectedAccount.accountIndex }

    /// The selected account's derivation path for a key (see `WalletAccount.derivationPath`). `nil`
    /// for a single-key `.wif` wallet, which has no derivation.
    public func derivationPath(isChange: Bool, index: Int32) -> String? {
        if keyType == .wif { return nil }
        return selectedAccount.derivationPath(isChange: isChange, index: index)
    }

    /// The seed's master fingerprint, read from the selected account (identical on every account).
    var masterFingerprint: String? { selectedAccount.masterFingerprint }

    /// `wpkh([d34db33f/84'/1'/0']tpub…/0/*)#…` → `m/84'/1'/0'`. Hardened markers are normalised to
    /// `'` (BDK may write `h`). `nil` when there's no `[fingerprint/path]` origin.
    static func keyOriginPath(_ descriptor: String) -> String? {
        let opened = descriptor.components(separatedBy: "[")
        guard opened.count > 1 else { return nil }
        let origin = opened[1].components(separatedBy: "]")
        guard origin.count > 1 else { return nil }
        var steps = origin[0].components(separatedBy: "/")
        guard steps.count > 1 else { return nil }
        steps.removeFirst()   // the master fingerprint
        return "m/" + steps.joined(separator: "/").replacingOccurrences(of: "h", with: "'")
    }

    /// `wpkh([D34DB33F/84'/0'/0']xpub…)` → `"d34db33f"`; `nil` without an origin or if the
    /// fingerprint isn't 8 hex digits. Character-by-character in a plain loop: `UInt32(_:radix:)`
    /// and `String.allSatisfy` have no Kotlin counterpart in Skip, and an `Int` radix parse would
    /// overflow Kotlin's 32-bit Int on fingerprints above 0x7fffffff.
    static func masterFingerprint(_ descriptor: String) -> String? {
        let opened = descriptor.components(separatedBy: "[")
        guard opened.count > 1 else { return nil }
        let origin = opened[1].components(separatedBy: "]")
        guard origin.count > 1 else { return nil }
        let steps = origin[0].components(separatedBy: "/")
        guard let first = steps.first else { return nil }
        let fp = first.lowercased()
        guard fp.count == 8 else { return nil }
        let hexDigits = "0123456789abcdef"
        for ch in fp {
            if !hexDigits.contains(String(ch)) { return nil }
        }
        return fp
    }
}

/// One of this wallet's keys that a transaction touched: an output paying one of our addresses, or an
/// input spending from one. Lets tx detail show which derivation path(s) were involved — turn it into
/// a path with `ManagedWallet.derivationPath(isChange:index:)`. Signed `Int32` index (bridge rule).
public struct TxKeyUse: Equatable, Hashable, Sendable {
    /// True when the tx SPENT this key's coin (an input); false when it paid to it (an output).
    public let isInput: Bool
    /// The internal (change) keychain, `…/1/i`, vs the external (receive) one, `…/0/i`.
    public let isChange: Bool
    public let index: Int32
    public init(isInput: Bool, isChange: Bool, index: Int32) {
        self.isInput = isInput
        self.isChange = isChange
        self.index = index
    }
}

/// A receive address plus its derivation index, derived from BDK.
/// `index` is Int32 (not BDK's UInt32) — bridged properties must avoid unsigned types (see
/// Amount); BIP32 indices are < 2^31 so the conversion at the BDK boundary is lossless.
public struct AddressInfo: Equatable, Hashable, Sendable {
    public let address: String
    public let index: Int32
    public init(address: String, index: Int32) {
        self.address = address
        self.index = index
    }
}

/// An unspent output owned by a wallet.
/// `vout` is Int32 (not BDK's UInt32) — bridged properties must avoid unsigned types (see Amount).
public struct Utxo: Equatable, Hashable, Sendable {
    public let txid: String
    public let vout: Int32
    public let amount: Amount
    public init(txid: String, vout: Int32, amount: Amount) {
        self.txid = txid
        self.vout = vout
        self.amount = amount
    }
}

/// A read-only summary of a wallet's coin-split status: how much is drainable, and how much of that
/// Bitcoin's explorer reported as still live on Bitcoin (shared → needs splitting). Drives the split
/// nudge + the amount shown in the flow. Bridge-safe (signed Int fields).
public struct SplitSummary: Equatable, Sendable {
    /// Total spendable sats — what a "Split" (drain) would move.
    public let spendableSats: Int64
    /// Sats in coins Bitcoin reported as shared — the amount that actually *needs* splitting
    /// (`< spendableSats` when the wallet also holds safe or unchecked coins).
    public let needsSplitSats: Int64
    /// Number of shared UTXOs that need splitting. `0` → nothing to split (don't nudge).
    public let needsSplitCount: Int32
    /// Sats we can't vouch for either way — see `unverifiedCount`.
    public let unverifiedSats: Int64
    /// UTXOs Bitcoin hasn't been asked about yet (or the check couldn't reach it).
    ///
    /// Kept separate from `needsSplitCount` on purpose: unverified coins must not drive the Home
    /// nudge — only an actual answer from Bitcoin does. They're what the Bitcoin check resolves.
    public let unverifiedCount: Int32

    public init(spendableSats: Int64, needsSplitSats: Int64, needsSplitCount: Int32,
                unverifiedSats: Int64 = 0, unverifiedCount: Int32 = Int32(0)) {
        self.spendableSats = spendableSats
        self.needsSplitSats = needsSplitSats
        self.needsSplitCount = needsSplitCount
        self.unverifiedSats = unverifiedSats
        self.unverifiedCount = unverifiedCount
    }
}

extension SplitSummary {
    /// Classify spendable UTXOs by what **Bitcoin** said about each one — nothing else.
    ///
    /// `knownShared` / `knownSafe` are outpoint keys ("txid:vout") resolved by asking Bitcoin's
    /// explorer directly (`SplitCheckService`). A coin in neither list hasn't been checked (or the
    /// check couldn't reach Bitcoin) and lands in `unverified`: it never drives the nudge.
    ///
    /// There is deliberately **no height heuristic**. Confirmation height against the fork is only a
    /// proxy, and it's wrong in both directions: a pre-fork coin already spent on Bitcoin can't be
    /// replayed (over-reports), and a post-fork coin from a non-replay-protected spend exists on both
    /// chains (under-reports — the dangerous direction). Removed 2026-10-10.
    ///
    /// Takes ARRAYS, not Sets, and converts internally: a `Set<String>` parameter makes Swift infer
    /// array literals at call sites as sets, but Skip transpiles those literals to Kotlin `Array`,
    /// and the Kotlin compile then fails with "actual type is 'Array<String>', but 'Set<String>' was
    /// expected". Only `skip test` catches that — the Swift build is perfectly happy.
    static func classify(_ spendable: [SplitUtxo],
                         knownShared: [String] = [], knownSafe: [String] = []) -> SplitSummary {
        let knownShared = Set(knownShared)
        let knownSafe = Set(knownSafe)
        var total: Int64 = 0
        var needSats: Int64 = 0
        var needCount: Int32 = 0
        var unverifiedSats: Int64 = 0
        var unverifiedCount: Int32 = 0
        for u in spendable {
            total += u.sats
            let key = u.outpointKey
            if knownShared.contains(key) {
                needSats += u.sats
                needCount += Int32(1)
            } else if knownSafe.contains(key) {
                continue                                  // Bitcoin never had it, or already spent it
            } else {
                unverifiedSats += u.sats
                unverifiedCount += Int32(1)
            }
        }
        return SplitSummary(spendableSats: total, needsSplitSats: needSats, needsSplitCount: needCount,
                            unverifiedSats: unverifiedSats, unverifiedCount: unverifiedCount)
    }
}

/// One spendable UTXO reduced to what classification needs: its outpoint and value. Internal — the
/// engine builds these from BDK's `LocalOutput`.
struct SplitUtxo: Equatable {
    let sats: Int64
    /// Outpoint, so a verification result from Bitcoin can be matched back to this coin.
    let txid: String
    let vout: Int32

    var outpointKey: String { "\(txid):\(vout)" }

    init(sats: Int64, txid: String, vout: Int32) {
        self.sats = sats
        self.txid = txid
        self.vout = vout
    }
}

/// A wallet transaction as surfaced to the UI. Positive `net` = received, negative = sent.
public struct WalletTx: Identifiable, Equatable, Hashable, Sendable {
    public let txid: String
    /// Signed net effect on this wallet's balance, in sats. Int64 (64-bit) is required —
    /// not Swift `Int`, which transpiles to 32-bit Kotlin `Int`.
    public let netSats: Int64
    /// Fee and confirmation count are SIGNED (Int64/Int32), not UInt64/UInt32, on purpose:
    /// Kotlin compiles unsigned types as inline value classes and MANGLES their property
    /// getters' JVM names (`getConfirmations-pVg5ArA`), so Skip's generated bridge can't find
    /// them via JNI and the app crashes on first access from native Swift on Android.
    /// Bridged property surfaces must stick to signed integers. (Constructors are unaffected —
    /// Kotlin emits an unmangled synthetic constructor the bridge uses.)
    public let feeSats: Int64?
    public let confirmations: Int32
    /// Block/confirmation time as a Unix epoch in seconds; nil if unconfirmed.
    /// We avoid Foundation.Date in WalletService's public API because it is not a
    /// bridged type across the Fuse JNI boundary (`bridging: true`). The view layer
    /// converts to Date for display — "format at the edge only".
    public let timestampEpochSeconds: Int64?
    public let isRBF: Bool
    /// Height of the block that confirmed this tx; nil while unconfirmed. Signed Int64 for the
    /// same bridge reason as `confirmations` (no unsigned properties on bridged types).
    public let blockHeight: Int64?
    /// Virtual size in vbytes (BIP141 weight units / 4, rounded up). Used to derive the fee rate
    /// at the display edge. Signed Int64 (see above); nil if unknown.
    public let vsize: Int64?

    /// Value paid TO this wallet by this tx (BDK `sentAndReceived.received`), in sats.
    ///
    /// Needed because `netSats` alone can't describe a **self-transfer**: a split moves the whole
    /// balance to our own address, so the net is only `-fee` and the amount that actually moved
    /// appears nowhere. This carries it. (For an ordinary send this is just the change; for a
    /// receive it equals `netSats`.) Signed `Int64` like every other bridged number — unsigned
    /// properties crash the JNI bridge (see `feeSats`).
    public let receivedSats: Int64?

    /// If this tx carries a CoinNews `OP_RETURN`, its kind ("topic"/"story"/"comment"/"upvote"/
    /// "downvote"/"continuation"); nil for ordinary transactions. Detected from the output scripts at
    /// the engine boundary (the bridged surface stays String — never a raw enum). Lets the UI mark it.
    public let coinNewsKind: String?

    /// If this tx is a BIP300 **deposit** to a sidechain (M5), the slot it credits (0–255); nil
    /// otherwise. Detected from the output scripts at the engine boundary (`Drivechain.deposit`),
    /// using this network's `OP_DRIVECHAIN` opcode. The app maps slot → name from the enforcer.
    /// `Int32`, signed, for the bridge (see `feeSats`).
    public let sidechainDepositSlot: Int32?
    /// The sidechain address a deposit credits, as carried in its OP_RETURN (the bare address, not
    /// the `s9_…_checksum` display form). Non-nil exactly when `sidechainDepositSlot` is.
    public let sidechainDepositAddress: String?
    /// If this tx is a sidechain → mainchain **withdrawal** (a sidechain wallet's `Withdrawal` output),
    /// the mainchain address it pays; nil otherwise. Empty string when the backend reports a withdrawal
    /// without its destination.
    public let sidechainWithdrawalAddress: String?

    /// True when this tx was confirmed BELOW the network's fork height: it's part of the history the
    /// eCash chain inherited from Bitcoin, so it exists on both chains. Real, and shown, but labelled
    /// (an imported pre-fork key otherwise looks like it's showing "Bitcoin transactions"). Always
    /// false on networks that never forked and for unconfirmed txs.
    public let isBeforeFork: Bool

    /// This wallet's keys the tx touched (inputs spent + outputs received), in tx order. Empty when
    /// unknown — e.g. the optimistic copy returned straight from a send, before the next history load.
    public let ownKeys: [TxKeyUse]

    public var id: String { txid }

    public init(txid: String, netSats: Int64, feeSats: Int64?,
                confirmations: Int32, timestampEpochSeconds: Int64?, isRBF: Bool,
                blockHeight: Int64? = nil, vsize: Int64? = nil, coinNewsKind: String? = nil,
                receivedSats: Int64? = nil,
                sidechainDepositSlot: Int32? = nil, sidechainDepositAddress: String? = nil,
                sidechainWithdrawalAddress: String? = nil,
                isBeforeFork: Bool = false,
                ownKeys: [TxKeyUse] = []) {
        self.ownKeys = ownKeys
        self.isBeforeFork = isBeforeFork
        self.sidechainWithdrawalAddress = sidechainWithdrawalAddress
        self.receivedSats = receivedSats
        self.sidechainDepositSlot = sidechainDepositSlot
        self.sidechainDepositAddress = sidechainDepositAddress
        self.txid = txid
        self.netSats = netSats
        self.feeSats = feeSats
        self.confirmations = confirmations
        self.timestampEpochSeconds = timestampEpochSeconds
        self.isRBF = isRBF
        self.blockHeight = blockHeight
        self.vsize = vsize
        self.coinNewsKind = coinNewsKind
    }

    /// True if this transaction is a CoinNews post (any kind).
    public var isCoinNews: Bool { coinNewsKind != nil }

    /// Whether a tx confirmed at `blockHeight` predates a fork at `forkHeight`. The fork block
    /// itself is the first chain-specific block (same boundary as `SplitSummary.classify`), so
    /// only heights strictly below it are shared history.
    public static func isBeforeFork(blockHeight: Int64?, forkHeight: Int64?) -> Bool {
        guard let height = blockHeight, let fork = forkHeight else { return false }
        return height < fork
    }

    /// This transaction with a different timestamp and every other field unchanged. Use this rather
    /// than rebuilding a `WalletTx` field by field: a hand copy silently drops whatever field is added
    /// next (it dropped the sidechain-deposit fields from Thunder history once).
    public func withTimestamp(_ epochSeconds: Int64?) -> WalletTx {
        WalletTx(txid: txid, netSats: netSats, feeSats: feeSats, confirmations: confirmations,
                 timestampEpochSeconds: epochSeconds, isRBF: isRBF, blockHeight: blockHeight, vsize: vsize,
                 coinNewsKind: coinNewsKind, receivedSats: receivedSats,
                 sidechainDepositSlot: sidechainDepositSlot, sidechainDepositAddress: sidechainDepositAddress,
                 sidechainWithdrawalAddress: sidechainWithdrawalAddress,
                 isBeforeFork: isBeforeFork, ownKeys: ownKeys)
    }

    /// True if this transaction deposited coins into a sidechain.
    public var isSidechainDeposit: Bool { sidechainDepositSlot != nil }

    /// True if this transaction withdraws coins from a sidechain back to its mainchain.
    public var isSidechainWithdrawal: Bool { sidechainWithdrawalAddress != nil }

    public var isReceived: Bool { netSats >= 0 }
    public var isConfirmed: Bool { confirmations > 0 }

    /// True when this transaction only moved coins between **this wallet's own** addresses — a
    /// coin split, a sweep back to itself, or a CoinNews `OP_RETURN` post. Every input and every
    /// output belongs to us, so the only value that actually left the wallet is the fee, which is
    /// exactly what `netSats == -feeSats` says.
    ///
    /// Display code must special-case these: the usual "amount minus fee" (which answers *how much
    /// did the recipient get*) evaluates to **zero** here, because there is no recipient. A split
    /// that moved a whole balance would render as `0.00000000`, reading as "nothing happened".
    /// Confirmed, but we don't know how deep — the engine could establish that it's in a block
    /// without learning the height.
    ///
    /// Only Thunder produces this today: its node exposes no per-transaction height (see
    /// `ThunderHistory`), yet anything visible in the node's state is necessarily in a connected
    /// block. BDK always knows the height when confirmed, so its transactions never hit this.
    /// Display code must not print a confirmation count or a date for these — the count would be a
    /// floor presented as fact, and the only timestamp we have is when this device first saw it.
    public var isConfirmedDepthUnknown: Bool { confirmations > 0 && blockHeight == nil }

    public var isSelfTransfer: Bool {
        guard let feeSats, netSats < 0 else { return false }
        return -netSats == feeSats
    }

    /// Fee rate in sat/vByte, or nil if the fee or size is unknown. A method (not a property) so
    /// the `Double` return never lands on the bridged property surface; computed for display only.
    public func feeRatePerVByte() -> Double? {
        guard let feeSats, let vsize, vsize > 0 else { return nil }
        return Double(feeSats) / Double(vsize)
    }
}

// `Codable` lives in EXTENSIONS, not the primary declarations above, on purpose: Skip's bridge
// generator copies a type's primary-declaration conformance list onto its JNI-peer bridge struct,
// and a peer struct (stored `Java_peer: JObject`) can't synthesize `Codable` → "does not conform".
// `WalletNetwork` (a String enum) bridges + Codables cleanly. `ManagedWallet` (a struct) does NOT —
// the bridge generator copies even an extension's `Codable` onto the peer struct, which then can't
// synthesize it. So `ManagedWallet` stays non-Codable and `FileWalletStore` persists it through a
// private Codable DTO instead (see WalletStore.swift).
extension WalletNetwork: Codable {}
extension WalletKeyType: Codable {}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
