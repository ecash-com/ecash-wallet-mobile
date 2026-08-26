// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// A payment link's URI scheme, which is the ONLY way a sender can say which chain they mean.
///
/// eCash is byte-identical to Bitcoin — same address format, same `bc` HRP — so `bc1q…` is
/// simultaneously a valid Bitcoin and a valid eCash address. Nothing in the address distinguishes
/// them. `ecash:` therefore isn't parity with `bitcoin:`; it's the only disambiguation channel that
/// exists (docs/uri-scheme-deep-links.md §2).
public enum PaymentScheme: String, Sendable {
    case bitcoin
    case ecash
    /// A bare address, with no scheme — our own Receive QR, and most pasted addresses.
    case none
}

/// Which wallets a payment link may be paid from, and why it can't be paid when it can't.
public struct PaymentLinkRouting: Equatable, Sendable {
    /// Networks whose wallets may pay this link. Empty = nothing can.
    public let networks: [WalletNetwork]
    /// Set when the link can't be paid at all, explaining WHY — a user must be able to tell a
    /// missing wallet from a wrong-chain link.
    public let rejection: String?
    /// True when the address alone can't say which chain is meant, so the user must choose.
    public let isAmbiguous: Bool

    public init(networks: [WalletNetwork], rejection: String? = nil, isAmbiguous: Bool = false) {
        self.networks = networks
        self.rejection = rejection
        self.isAmbiguous = isAmbiguous
    }
}

/// Parses `bitcoin:`/`ecash:` payment links and decides which wallets may pay them.
///
/// Pure and Skip-safe: this is the money-safety core of deep linking, so it's unit-tested away from
/// any UI or platform plumbing.
public enum PaymentLink {

    /// Split a raw link into its scheme and the BIP21 body (address plus any query).
    public static func scheme(of raw: String) -> PaymentScheme {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("bitcoin:") { return .bitcoin }
        if trimmed.hasPrefix("ecash:") { return .ecash }
        return PaymentScheme.none
    }

    /// The part after the scheme, ready for `BIP21.parse`.
    public static func body(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("bitcoin:") { return String(trimmed.dropFirst("bitcoin:".count)) }
        if lower.hasPrefix("ecash:") { return String(trimmed.dropFirst("ecash:".count)) }
        return trimmed
    }

    /// True for an eCash **(XEC)** CashAddr — the unrelated Bitcoin ABC fork, which has used the
    /// `ecash:` scheme since 2021.
    ///
    /// We accept that collision rather than avoid it (docs §3.4): it's symmetric, and an XEC address
    /// can't be confused with ours. CashAddr payloads are lowercase bech32-charset strings beginning
    /// `q` (P2PKH) or `p` (P2SH), which cannot collide with `bc1…`, `1…` or `3…`. Detecting it lets
    /// us say something true instead of failing obscurely.
    public static func isXECCashAddr(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a.count >= 20, let first = a.first, first == "q" || first == "p" else { return false }
        // bech32 charset — excludes 1, b, i and o, which is what keeps `bc1…` out.
        let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        for character in a where !charset.contains(character) { return false }
        return true
    }

    /// Address class, used when the scheme doesn't name a chain.
    /// `tb1…` is testnet-class; `bc1…`/`1…`/`3…` are mainnet-class and shared by Bitcoin AND eCash.
    private static func isTestnetClass(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return a.hasPrefix("tb1") || a.hasPrefix("m") || a.hasPrefix("n") || a.hasPrefix("2")
    }

    /// Decide which networks may pay this link.
    ///
    /// Scheme wins where it's present, per the strict mapping in docs §3.2 — a scheme is a statement
    /// about the chain and we honor it. A bare address can't make that statement, so mainnet-class
    /// addresses stay ambiguous and the user chooses; picking wrongly there sends real value to a
    /// chain the payee will never watch, which is why we ask rather than guess.
    public static func routing(scheme: PaymentScheme, address: String) -> PaymentLinkRouting {
        if isXECCashAddr(address) {
            return PaymentLinkRouting(networks: [],
                                      rejection: "That's an eCash (XEC) address. This wallet is for eCash (ECX).")
        }
        if isTestnetClass(address) {
            return PaymentLinkRouting(networks: [.signet])
        }
        switch scheme {
        case .bitcoin:
            return PaymentLinkRouting(networks: [.bitcoin])
        case .ecash:
            return PaymentLinkRouting(networks: [.ecash])
        case PaymentScheme.none:
            // No scheme, mainnet-class address: valid on both chains, and nothing says which.
            return PaymentLinkRouting(networks: [.bitcoin, .ecash], isAmbiguous: true)
        }
    }

    /// Why nothing can pay this link, given the wallets that exist. Says WHICH chain was asked for,
    /// so a missing wallet is distinguishable from a wrong-chain link.
    public static func noWalletMessage(for routing: PaymentLinkRouting) -> String {
        if let rejection = routing.rejection { return rejection }
        if routing.isAmbiguous { return "You don't have a Bitcoin or eCash wallet." }
        guard let network = routing.networks.first else { return "No wallet can pay this request." }
        switch network {
        case .bitcoin: return "This is a Bitcoin payment request. You don't have a Bitcoin wallet."
        case .ecash: return "This is an eCash payment request. You don't have an eCash wallet."
        case .signet: return "You don't have a signet wallet."
        case .thunder: return "No wallet can pay this request."
        }
    }
}

#endif // !SKIP_BRIDGE
