// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One asset's price from one public ticker. Display data only — never wallet money, so `Double` is
/// fine here (wallet amounts stay `Int64` sats, CLAUDE.md §6).
///
/// Quotes are in the venue's dollar (USDT on Gate.io and NonKYC). The UI shows "$" and the Markets
/// footnote says so, rather than converting between stablecoins.
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

/// The market section: the comparison table. There is no ECX quote yet — real ECX is not listed on
/// any keyless venue (Gate.io and NonKYC checked 2026-10-29), and the Betanet wbECX row (Solana, ×50
/// implied price) was dropped with Betanet when the dashboard moved to mainnet (2026-10-29).
struct MarketBoard: Equatable, Codable, Sendable {
    /// BTC, BCH, BSV, BTCB2 — whichever loaded, in that order.
    let quotes: [MarketQuote]
    /// ECX, as the wECX / USDC Orca pool on Solana prices it (GeckoTerminal; the pool CoinMarketCap
    /// quotes). The Dashboard's headline card. Nil when the pool call failed. Optional so a cached
    /// board written before this field decodes.
    var ecx: MarketQuote? = nil

    /// Every row for the markets table: ECX first (it is the coin this app is for), then the
    /// Bitcoin forks in their fixed order.
    var allQuotes: [MarketQuote] {
        if let ecx { return [ecx] + quotes }
        return quotes
    }
}
