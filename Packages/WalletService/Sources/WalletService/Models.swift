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
    /// The eCash fork. Currently backed by the **drynet2** dry-run chain (see
    /// `NetworkRegistry`); the case is named `.ecash` now — its rawValue is persisted in the
    /// wallet store + backend-override keys — so it survives the eventual drynet2→eCash rename
    /// without a data migration. eCash is byte-identical to Bitcoin (mainnet `bc` HRP,
    /// coin-type `0'`), so it maps to BDK `Network.bitcoin`; it is separated from Bitcoin only
    /// by its backend. Unit label is **ECX**. (See `docs/key-derivation.md`, memory
    /// `drynet2-ecash-network`.)
    case ecash

    /// True for everything that is NOT Bitcoin mainnet. Drives the persistent network
    /// badge (Golden Rule §6) — non-mainnet wallets must be unmistakable. `.ecash` is a
    /// **test** chain (drynet2) that nonetheless uses mainnet-style `bc` addresses, so it stays
    /// non-mainnet here (violet chip, no real-money warnings) even though its addresses look
    /// identical to real Bitcoin — the chip is the only thing distinguishing them.
    public var isMainnet: Bool {
        self == .bitcoin
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

// MARK: - Wallet & chain value types

/// Metadata describing one managed wallet. Contains NO private key material
/// (Golden Rule §5) — mnemonics live in the Keychain keyed by `id`.
public struct ManagedWallet: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var label: String
    public let network: WalletNetwork
    /// Public (xpub-based) descriptors — never the private variants. For a `.wif` wallet these are
    /// the single-key public descriptor `pkh(<pubkey>)` (external == internal — one address).
    public var externalDescriptor: String
    public var internalDescriptor: String
    /// Whether this wallet is a mnemonic (HD) wallet or a single legacy private key (`.wif`).
    /// Lets the engine pick the right construction/signing path. Defaults to `.mnemonic`.
    public let keyType: WalletKeyType
    public var isBackedUp: Bool
    public var sortIndex: Int

    public init(id: String, label: String, network: WalletNetwork,
                externalDescriptor: String, internalDescriptor: String,
                keyType: WalletKeyType = .mnemonic,
                isBackedUp: Bool = false, sortIndex: Int = 0) {
        self.id = id
        self.label = label
        self.network = network
        self.externalDescriptor = externalDescriptor
        self.internalDescriptor = internalDescriptor
        self.keyType = keyType
        self.isBackedUp = isBackedUp
        self.sortIndex = sortIndex
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

    /// If this tx carries a CoinNews `OP_RETURN`, its kind ("topic"/"story"/"comment"/"upvote"/
    /// "downvote"/"continuation"); nil for ordinary transactions. Detected from the output scripts at
    /// the engine boundary (the bridged surface stays String — never a raw enum). Lets the UI mark it.
    public let coinNewsKind: String?

    public var id: String { txid }

    public init(txid: String, netSats: Int64, feeSats: Int64?,
                confirmations: Int32, timestampEpochSeconds: Int64?, isRBF: Bool,
                blockHeight: Int64? = nil, vsize: Int64? = nil, coinNewsKind: String? = nil) {
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

    public var isReceived: Bool { netSats >= 0 }
    public var isConfirmed: Bool { confirmations > 0 }

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
