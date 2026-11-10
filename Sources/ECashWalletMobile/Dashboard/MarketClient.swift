// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Reads the market section from two public, keyless tickers (`docs/dashboard-plan.md` §4.2):
///
///   * **Gate.io** — BTC, BCH, BSV (`/api/v4/spot/tickers?currency_pair=…_USDT`)
///   * **NonKYC** — BTCB2 (`/api/v2/market/getbysymbol/BTCB2_USDT`)
///
/// ECX comes from eCash.com's own price API (`EcashPriceProvider`, since 2026-11-09; the wECX Orca
/// pool via GeckoTerminal before that, and before that nothing — see §10). It is the headline card
/// and the first row of the table.
///
/// Not CoinGecko (product decision). Each asset is fetched on its own and a failure only drops that
/// row, so one venue being down never blanks the table; `board()` throws only when nothing loaded.
struct MarketClient: Sendable {
    let fetch: DashboardFetch

    /// Gate pairs, in table order.
    static let gateAssets: [(id: String, name: String, pair: String, ticker: String)] = [
        ("btc", "Bitcoin", "BTC_USDT", "BTC"),
        ("bch", "Bitcoin Cash", "BCH_USDT", "BCH"),
        ("bsv", "Bitcoin SV", "BSV_USDT", "BSV"),
        // XEC (Bitcoin ABC's eCash) was listed here until 2026-11-05 — dropped (Jake): a different
        // project that happens to share our name, and a row that only invited confusion.
    ]

    func board() async throws -> MarketBoard {
        // All four in flight at once; each `try?` so one venue failing only drops its row.
        let assets = Self.gateAssets
        async let btc = try? gate(assets[0])
        async let bch = try? gate(assets[1])
        async let bsv = try? gate(assets[2])
        async let btcb2 = try? nonKYCBTCB2()
        async let ecx = try? ecxFromEcashCom()
        let quotes: [MarketQuote?] = [await btc, await bch, await bsv, await btcb2]
        let loaded = quotes.compactMap { $0 }
        let ecxQuote = await ecx
        if loaded.isEmpty && ecxQuote == nil { throw DashboardError.malformed("markets: every source failed") }
        return MarketBoard(quotes: loaded, ecx: ecxQuote)
    }

    // MARK: - ECX (eCash.com price API — keyless)

    static let ecxPriceURL = EcashPriceProvider.endpoint

    func ecxFromEcashCom() async throws -> MarketQuote {
        guard let url = URL(string: Self.ecxPriceURL) else { throw DashboardError.malformed("ecash.com: url") }
        let data = try await DashboardHTTP.get(url, using: fetch)
        guard let quote = try? EcashPriceProvider.parse(data) else { throw DashboardError.malformed("ecash.com") }
        return Self.quote(ecx: quote)
    }

    /// No 24h change: the API doesn't publish one, and the row/card simply omit it.
    static func quote(ecx: EcashPriceProvider.Quote) -> MarketQuote {
        MarketQuote(id: "ecx", name: "eCash", ticker: "ECX", price: ecx.priceUSD,
                    change24h: nil, volume24h: ecx.volume24hUSD, source: "eCash.com")
    }

    // MARK: - Gate.io

    func gate(_ asset: (id: String, name: String, pair: String, ticker: String)) async throws -> MarketQuote {
        let url = try DashboardHTTP.url("https://api.gateio.ws", "/api/v4/spot/tickers?currency_pair=\(asset.pair)")
        let rows = try await DashboardHTTP.decode([GateTicker].self, from: url, using: fetch, route: "gate")
        guard let row = rows.first(where: { $0.currencyPair == asset.pair }) ?? rows.first else {
            throw DashboardError.malformed("gate: no row")
        }
        return try Self.quote(gate: row, id: asset.id, name: asset.name, ticker: asset.ticker)
    }

    static func quote(gate row: GateTicker, id: String, name: String, ticker: String) throws -> MarketQuote {
        guard let price = Double(row.last), price > 0 else { throw DashboardError.malformed("gate: last") }
        return MarketQuote(id: id, name: name, ticker: ticker, price: price,
                           change24h: row.changePercentage.flatMap(Double.init),
                           volume24h: row.quoteVolume.flatMap(Double.init), source: "Gate.io")
    }

    // MARK: - NonKYC

    func nonKYCBTCB2() async throws -> MarketQuote {
        let url = try DashboardHTTP.url("https://api.nonkyc.io", "/api/v2/market/getbysymbol/BTCB2_USDT")
        let row = try await DashboardHTTP.decode(NonKYCMarket.self, from: url, using: fetch, route: "nonkyc")
        return try Self.quote(nonKYC: row)
    }

    /// NonKYC gives last and yesterday's price, and volume in BTCB2 — so the change and the dollar
    /// volume are derived here.
    static func quote(nonKYC row: NonKYCMarket) throws -> MarketQuote {
        guard let price = Double(row.lastPrice), price > 0 else { throw DashboardError.malformed("nonkyc: lastPrice") }
        var change: Double? = nil
        if let yesterday = row.yesterdayPrice.flatMap(Double.init), yesterday > 0 {
            change = (price - yesterday) / yesterday * 100
        }
        return MarketQuote(id: "btcb2", name: "Bitcoin BLAKE2b", ticker: "BTCB2", price: price,
                           change24h: change, volume24h: row.volume.flatMap(Double.init).map { $0 * price },
                           source: "NonKYC")
    }
}

// MARK: - Wire types (only the fields we read; numbers arrive as strings on Gate and NonKYC)

struct GateTicker: Decodable {
    let currencyPair: String
    let last: String
    let changePercentage: String?
    let quoteVolume: String?

    enum CodingKeys: String, CodingKey {
        case last
        case currencyPair = "currency_pair"
        case changePercentage = "change_percentage"
        case quoteVolume = "quote_volume"
    }
}

struct NonKYCMarket: Decodable {
    let lastPrice: String
    let yesterdayPrice: String?
    let volume: String?
}
