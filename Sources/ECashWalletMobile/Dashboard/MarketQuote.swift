// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One asset's price from one public ticker. Display data only — never wallet money, so `Double` is
/// fine here (wallet amounts stay `Int64` sats, CLAUDE.md §6).
///
/// Quotes are in the venue's dollar: USDT on Gate.io and NonKYC, USDC for wbECX. The UI shows
/// "$" and the Markets footnote says which is which, rather than converting between stablecoins.
struct MarketQuote: Equatable, Codable, Sendable, Identifiable {
    let id: String          // stable asset id ("btc")
    let name: String        // "Bitcoin"
    let ticker: String      // "BTC"
    let price: Double
    /// 24h change in percent (−3.73 = down 3.73%); nil when the venue doesn't say.
    let change24h: Double?
    /// 24h traded value in the quote currency; nil when unknown.
    let volume24h: Double?
    /// The venue, for attribution ("Gate.io").
    let source: String
}

/// The market section: the comparison table plus wbECX, the only ECX price there is before mainnet.
struct MarketBoard: Equatable, Codable, Sendable {
    /// BTC, BCH, BSV, XEC, BTCB2 — whichever loaded, in that order.
    let quotes: [MarketQuote]
    /// Wrapped betanet ECX on Solana (Orca pool), via Jupiter + Orca. Nil if both failed.
    let wbECX: MarketQuote?

    /// The ECX price implied by the wrapped token: `wbECX × ecxPerWbECX`.
    ///
    /// The reference dashboard uses ×50 ("wbECX × 50, using 20M ECX"). **What the ratio means is an
    /// open question** (`docs/dashboard-plan.md` O2), so the UI shows the wbECX price as the headline
    /// and this only as a labelled secondary line — the derivation is never hidden.
    var impliedECXPrice: Double? { wbECX.map { $0.price * MarketBoard.ecxPerWbECX } }

    static let ecxPerWbECX: Double = 50
}
