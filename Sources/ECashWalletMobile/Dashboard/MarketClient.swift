// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Reads the market section from three public, keyless tickers (`docs/dashboard-plan.md` §4.2):
///
///   * **Gate.io** — BTC, BCH, BSV, XEC (`/api/v4/spot/tickers?currency_pair=…_USDT`)
///   * **NonKYC** — BTCB2 (`/api/v2/market/getbysymbol/BTCB2_USDT`)
///   * **Jupiter** (price + 24h change) and **Orca** (24h volume; fallback price) — wbECX, the Orca
///     pool on Solana. DexScreener was the first choice but dropped the pool on 2026-10-07 (it answers
///     `"pairs": null`); these two read the pool and the token directly.
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
    /// The wbECX SPL token mint, and USDC's — the pool's two sides.
    static let wbECXMint = "EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq"
    static let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    func board() async throws -> MarketBoard {
        // All six in flight at once; each `try?` so one venue failing only drops its row.
        let assets = Self.gateAssets
        async let btc = try? gate(assets[0])
        async let bch = try? gate(assets[1])
        async let bsv = try? gate(assets[2])
        async let xec = try? gate(assets[3])
        async let btcb2 = try? nonKYCBTCB2()
        async let wbecx = try? wbECX()
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

    // MARK: - wbECX (Jupiter + Orca)

    /// wbECX from both sources at once: Jupiter's aggregated price and 24h change, Orca's pool volume.
    /// Either alone still yields a row — Orca's own pool price stands in when Jupiter is down.
    func wbECX() async throws -> MarketQuote {
        async let jupiter = try? jupiterPrice()
        async let pool = try? orcaPool()
        return try Self.quote(jupiter: await jupiter, orca: await pool)
    }

    func jupiterPrice() async throws -> JupiterPrice.Entry {
        let url = try DashboardHTTP.url("https://lite-api.jup.ag", "/price/v3?ids=\(Self.wbECXMint)")
        let prices = try await DashboardHTTP.decode([String: JupiterPrice.Entry].self, from: url, using: fetch, route: "jupiter")
        guard let entry = prices[Self.wbECXMint] else { throw DashboardError.malformed("jupiter: no wbECX") }
        return entry
    }

    func orcaPool() async throws -> OrcaPool.Pool {
        let url = try DashboardHTTP.url("https://api.orca.so", "/v2/solana/pools/\(Self.orcaPool)")
        return try await DashboardHTTP.decode(OrcaPool.self, from: url, using: fetch, route: "orca").data
    }

    static func quote(jupiter: JupiterPrice.Entry?, orca: OrcaPool.Pool?) throws -> MarketQuote {
        let volume = orca?.stats?.day?.volume.flatMap(Double.init)
        if let jupiter, jupiter.usdPrice > 0 {
            return MarketQuote(id: "wbecx", name: "Wrapped ECX (Betanet)", ticker: "wbECX", price: jupiter.usdPrice,
                               change24h: jupiter.priceChange24h, volume24h: volume, source: "Jupiter · Orca")
        }
        if let orca, let price = orca.usdPriceOfWbECX {
            return MarketQuote(id: "wbecx", name: "Wrapped ECX (Betanet)", ticker: "wbECX", price: price,
                               change24h: nil, volume24h: volume, source: "Orca")
        }
        throw DashboardError.malformed("wbECX: no source")
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

/// `lite-api.jup.ag/price/v3?ids=<mint>` — keyed by mint.
enum JupiterPrice {
    struct Entry: Decodable {
        let usdPrice: Double
        let priceChange24h: Double?
    }
}

/// `api.orca.so/v2/solana/pools/<address>` — only the fields we read.
struct OrcaPool: Decodable {
    let data: Pool

    struct Pool: Decodable {
        /// Token A priced in token B. This pool is A = USDC, B = wbECX, so it's wbECX per USDC.
        let price: String?
        let tokenA: Token
        let tokenB: Token
        let stats: Stats?

        /// The dollar price of wbECX, from the pool's own price — only when the pool really is
        /// USDC/wbECX in that order (inverting the wrong way round would be off by a factor of ~8).
        var usdPriceOfWbECX: Double? {
            guard let raw = price.flatMap(Double.init), raw > 0 else { return nil }
            if tokenA.address == MarketClient.usdcMint && tokenB.address == MarketClient.wbECXMint { return 1 / raw }
            if tokenA.address == MarketClient.wbECXMint && tokenB.address == MarketClient.usdcMint { return raw }
            return nil
        }
    }

    struct Token: Decodable { let address: String }

    struct Stats: Decodable {
        let day: Window?
        enum CodingKeys: String, CodingKey { case day = "24h" }
    }

    struct Window: Decodable { let volume: String? }
}
