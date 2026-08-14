// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// A parsed payment request — either a bare address or a BIP21 URI
/// (`bitcoin:<address>?amount=<btc>&label=<…>&message=<…>`). The Send flow parses scanned or
/// pasted input through this; the amount is converted to sats here (`Amount`), never floated.
// Public + bridged (promoted for the Send slice, as planned): the app's Send flow parses pasted
// input through `BIP21.parse` on both platforms. All members are bridge-safe (String/Amount?).
public struct BIP21: Equatable, Sendable {
    public let address: String
    /// Requested amount, if the URI specified one. BIP21 `amount` is in coins (BTC), decimal.
    public let amount: Amount?
    public let label: String?
    public let message: String?

    public init(address: String, amount: Amount? = nil, label: String? = nil, message: String? = nil) {
        self.address = address
        self.amount = amount
        self.label = label
        self.message = message
    }

    /// Parses a bare address or a BIP21 URI. Returns nil if there's no address, or if an
    /// `amount` is present but malformed (we reject the whole request rather than silently
    /// dropping a bad amount — money must be explicit, §2/§7). The address string itself is
    /// NOT validated here — that's BDK's job at send time (`Address(address:network:)`).
    public static func parse(_ raw: String) -> BIP21? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return nil }

        // Strip the "bitcoin:" scheme if present (case-insensitive). "bitcoin:".count == 8.
        var rest = input
        if input.lowercased().hasPrefix("bitcoin:") {
            rest = String(input.dropFirst(8))
        }

        // Separate address from the query string.
        let parts = rest.components(separatedBy: "?")
        let address = parts[0]
        if address.isEmpty { return nil }

        var amount: Amount? = nil
        var label: String? = nil
        var message: String? = nil

        if parts.count > 1 {
            for pair in parts[1].components(separatedBy: "&") {
                if pair.isEmpty { continue }
                let kv = pair.components(separatedBy: "=")
                let key = kv[0].lowercased()
                // Value is the first segment after '='. (Values containing '=' are rare in the
                // fields we read; amount never has one.)
                let value = kv.count > 1 ? kv[1] : ""
                // BIP21 REQUIRES that a client which doesn't implement a `req-`-prefixed variable
                // treat the ENTIRE URI as invalid. We implement none of them, so any `req-` is a
                // hard reject — never a silent skip.
                //
                // This is money-safety, not pedantry. A `req-` param means the payee's request is
                // only satisfied by honoring it (payjoin and similar). Ignoring it produces a
                // perfectly valid plain send that the payee may not credit: the coins leave, the
                // invoice stays unpaid, and nothing looked wrong at any point. Refusing a URI we
                // can only partly honor is the safe failure — the user can still pay another way.
                //
                // `key` is already lowercased, so `REQ-`/`Req-` are caught too. That's deliberately
                // stricter than the spec's literal casing: over-rejecting an exotic URI costs a
                // retry, under-rejecting one costs the payment.
                if key.hasPrefix("req-") { return nil }

                if key == "amount" {
                    guard let amt = Amount.fromCoin(value) else { return nil }
                    amount = amt
                } else if key == "label" {
                    label = value.removingPercentEncoding ?? value
                } else if key == "message" {
                    message = value.removingPercentEncoding ?? value
                }
                // Other unknown params are ignored — BIP21 allows extensions, and anything
                // without the `req-` prefix is by definition optional to honor.
            }
        }

        return BIP21(address: address, amount: amount, label: label, message: message)
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
