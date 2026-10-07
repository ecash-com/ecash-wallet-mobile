// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Reads the market section from three public, keyless tickers (`docs/dashboard-plan.md` §4.2):
///
///   * **Gate.io** — BTC, BCH, BSV, XEC (`/api/v4/spot/tickers?currency_pair=…_USDT`)
///   * **NonKYC** — BTCB2 (`/api/v2/market/getbysymbol/BTCB2_USDT`)
///   * **DexScreener** — wbECX, the Orca pool on Solana
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
        ("xec", "XEC", "XEC_USDT", "XEC"),
    ]
    static let orcaPool = "nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM"

    func board() async throws -> MarketBoard {
        // All six in flight at once; each `try?` so one venue failing only drops its row.
        let assets = Self.gateAssets
        async let btc = try? gate(assets[0])
        async let bch = try? gate(assets[1])
        async let bsv = try? gate(assets[2])
        async let xec = try? gate(assets[3])
        async let btcb2 = try? nonKYCBTCB2()
        async let wbecx = try? dexScreenerWbECX()
        let quotes: [MarketQuote?] = [await btc, await bch, await bsv, await xec, await btcb2]
        let wbECX = await wbecx
        let loaded = quotes.compactMap { $0 }
        if loaded.isEmpty && wbECX == nil { throw DashboardError.malformed("markets: every source failed") }
        return MarketBoard(quotes: loaded, wbECX: wbECX)
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

    // MARK: - DexScreener

    func dexScreenerWbECX() async throws -> MarketQuote {
        let url = try DashboardHTTP.url("https://api.dexscreener.com", "/latest/dex/pairs/solana/\(Self.orcaPool)")
        let response = try await DashboardHTTP.decode(DexScreenerResponse.self, from: url, using: fetch, route: "dexscreener")
        return try Self.quote(dexScreener: response)
    }

    static func quote(dexScreener response: DexScreenerResponse) throws -> MarketQuote {
        guard let pair = response.pairs?.first, let price = pair.priceUsd.flatMap(Double.init), price > 0 else {
            throw DashboardError.malformed("dexscreener: priceUsd")
        }
        return MarketQuote(id: "wbecx", name: "Wrapped ECX (Betanet)", ticker: "wbECX", price: price,
                           change24h: pair.priceChange?.h24, volume24h: pair.volume?.h24, source: "Orca · DexScreener")
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

struct DexScreenerResponse: Decodable {
    let pairs: [Pair]?

    struct Pair: Decodable {
        let priceUsd: String?
        let priceChange: Window?
        let volume: Window?
    }

    struct Window: Decodable { let h24: Double? }
}
