// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Typed errors out of WalletService. Raw BDK errors are mapped to these before they
/// ever reach the UI. CRITICAL (Golden Rule §2): no message in this
/// enum — or anything derived from it — may contain secret material (mnemonic, xprv,
/// or a descriptor with private keys). Map at the seam; scrub on the way out.
public enum WalletError: Error, Equatable, Sendable {
    case notImplemented
    case invalidMnemonic
    /// A private key (WIF) failed to parse, or doesn't match the chosen network. Never echoes the
    /// key itself (Golden Rule §2).
    case invalidPrivateKey
    case invalidDescriptor
    case invalidAddress
    case networkMismatch(expected: WalletNetwork)
    case insufficientFunds
    case dustAmount
    case noSpendableUtxos
    case syncFailed
    case broadcastFailed
    case signingFailed
    case persistenceFailed
    /// A BDK error we don't have a specific case for. The associated string is a
    /// pre-scrubbed, user-safe summary — never the raw BDK description.
    case engine(String)

    /// A safe, user-facing message. Deliberately vague where leaking detail would risk
    /// exposing key material — e.g. signing reports "signing failed", never the key.
    public var userMessage: String {
        switch self {
        case .notImplemented: return "This feature isn't available yet."
        case .invalidMnemonic: return "That recovery phrase isn't valid."
        case .invalidPrivateKey: return "That private key isn't valid for this network."
        case .invalidDescriptor: return "That wallet descriptor isn't valid."
        case .invalidAddress: return "That address isn't valid for this network."
        case .networkMismatch(let expected):
            return "This wallet belongs to a different network (expected \(expected.rawValue))."
        case .insufficientFunds: return "Not enough funds to cover this amount and fee."
        case .dustAmount: return "That amount is too small to send."
        case .noSpendableUtxos: return "There are no spendable coins in this wallet."
        case .syncFailed: return "Couldn't reach the network. Check your connection and try again."
        case .broadcastFailed: return "Couldn't broadcast the transaction. Try again."
        case .signingFailed: return "Signing failed."
        case .persistenceFailed: return "Couldn't save wallet data."
        case .engine(let summary): return summary
        }
    }
}

extension WalletError {
    /// Maps a raw error description (e.g. a BDK error's text) to a safe, typed `WalletError`
    /// WITHOUT ever echoing the raw text — a BDK error string can embed key material
    /// (descriptors-with-keys, xprv) and must never reach the UI (Golden Rule §2).
    ///
    /// The raw string is only *inspected* to classify the error; the returned case carries a
    /// fixed, pre-scrubbed message. Unrecognized errors collapse to a generic `.engine`
    /// summary — never the raw text.
    ///
    /// Classification keys off BDK's UniFFI error-variant names (`InsufficientFunds`,
    /// `OutputBelowDustLimit`, `NoUtxosSelected`, …). Those names are generated from the same Rust
    /// enums, so they appear IDENTICALLY in bdk-swift's `"\(error)"` and bdk-android's
    /// `.toString()` — token matching is the one mapping that's correct on BOTH platforms without
    /// an `#if SKIP` split (Swift models these as error enums, Kotlin as a different exception
    /// class, so a typed `catch as CreateTxError` would not transpile cleanly). Callers that
    /// already KNOW the context (sync, broadcast, signing) should throw the specific case directly
    /// rather than routing through here.
    public static func mapping(rawDescription raw: String) -> WalletError {
        let lower = raw.lowercased()
        if lower.contains("insufficient") { return .insufficientFunds } // CreateTxError.InsufficientFunds
        if lower.contains("dust") { return .dustAmount } // .OutputBelowDustLimit
        if lower.contains("noutxos") || lower.contains("no utxo") // .NoUtxosSelected
            || lower.contains("no spendable") || lower.contains("no outputs") {
            return .noSpendableUtxos
        }
        if lower.contains("checksum") || lower.contains("invalid mnemonic")
            || lower.contains("invalid word") || lower.contains("badword") { // Bip39Error.BadWordCount/…
            return .invalidMnemonic
        }
        if lower.contains("address") { return .invalidAddress } // AddressParseError
        if lower.contains("descriptor") { return .invalidDescriptor } // DescriptorError
        if lower.contains("network") && lower.contains("mismatch") { return .networkMismatch(expected: .bitcoin) }
        if lower.contains("sign") { return .signingFailed } // SignerError
        if lower.contains("broadcast") { return .broadcastFailed }
        if lower.contains("persist") || lower.contains("database") { return .persistenceFailed }
        if lower.contains("sync") || lower.contains("connect") || lower.contains("timeout")
            || lower.contains("allattemptserrored") || lower.contains("electrum") { // ElectrumError.*
            return .syncFailed
        }
        // Unknown — generic, fixed message. NEVER the raw text.
        return .engine("Something went wrong. Please try again.")
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
