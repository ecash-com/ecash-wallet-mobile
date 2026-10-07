// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// Market tickers, recorded from the live APIs on 2026-10-07 (trimmed to the fields we read).
@Suite struct MarketClientTests {
    static func gateURL(_ pair: String) -> String { "https://api.gateio.ws/api/v4/spot/tickers?currency_pair=\(pair)" }
    static let nonKYCURL = "https://api.nonkyc.io/api/v2/market/getbysymbol/BTCB2_USDT"
    static let jupiterURL = "https://lite-api.jup.ag/price/v3?ids=\(MarketClient.wbECXMint)"
    static let orcaURL = "https://api.orca.so/v2/solana/pools/\(MarketClient.orcaPool)"

    static let btcGate = #"[{"currency_pair":"BTC_USDT","last":"83237.6","change_percentage":"-3.73","quote_volume":"881200598.5151595"}]"#
    static let nonKYC = #"{"symbol":"BTCB2/USDT","lastPrice":"674.64","yesterdayPrice":"678.37","volume":"333.1556"}"#
    static let jupiter = #"{"EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq":{"createdAt":"2026-09-25T05:56:05Z","liquidity":32923.34,"usdPrice":2.8972424474144893,"blockId":454274207,"decimals":8,"priceChange24h":10.02810851993635}}"#
    /// Token A = USDC, B = wbECX, so `price` is wbECX per USDC.
    static let orca = #"{"data":{"address":"nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM","price":"0.35018320907438717400","tokenA":{"address":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","symbol":"USDC"},"tokenB":{"address":"EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq","symbol":"wbECX"},"stats":{"24h":{"volume":"1761.505040033780","fees":"103.16"}}}}"#

    @Test func gateTickersDecode() throws {
        let rows = try JSONDecoder().decode([GateTicker].self, from: Data(Self.btcGate.utf8))
        let quote = try MarketClient.quote(gate: rows[0], id: "btc", name: "Bitcoin", ticker: "BTC")
        #expect(quote.price == 83_237.6)
        #expect(quote.change24h == -3.73)
        #expect(quote.volume24h == 881_200_598.5151595)
        #expect(quote.source == "Gate.io")
    }

    @Test func nonKYCDerivesChangeAndDollarVolume() throws {
        let row = try JSONDecoder().decode(NonKYCMarket.self, from: Data(Self.nonKYC.utf8))
        let quote = try MarketClient.quote(nonKYC: row)
        #expect(quote.price == 674.64)
        // (674.64 − 678.37) / 678.37 × 100
        #expect(abs((quote.change24h ?? 0) - (-0.549847)) < 0.0001)
        // Volume is in BTCB2, so × price.
        #expect(abs((quote.volume24h ?? 0) - 333.1556 * 674.64) < 0.001)
    }

    @Test func wbECXTakesJupitersPriceAndOrcasVolume() async throws {
        let web = FakeDashboardWeb()
        web.on(Self.jupiterURL, Self.jupiter)
        web.on(Self.orcaURL, Self.orca)
        let quote = try await MarketClient(fetch: web.fetch).wbECX()
        #expect(quote.ticker == "wbECX")
        #expect(quote.price == 2.8972424474144893)
        #expect(quote.change24h == 10.02810851993635)
        #expect(quote.volume24h == 1_761.50504003378)
        let board = MarketBoard(quotes: [], wbECX: quote)
        #expect(board.impliedECXPrice == 2.8972424474144893 * 50)
    }

    @Test func orcaAloneStillPricesWbECX() async throws {
        let web = FakeDashboardWeb()
        web.on(Self.orcaURL, Self.orca)   // Jupiter down
        let quote = try await MarketClient(fetch: web.fetch).wbECX()
        #expect(abs(quote.price - 1 / 0.350183209074387174) < 1e-9)   // inverted: USDC per wbECX
        #expect(quote.change24h == nil)
        #expect(quote.source == "Orca")
    }

    @Test func anOrcaPoolOfOtherTokensIsNotInverted() throws {
        let json = #"{"data":{"price":"0.35","tokenA":{"address":"X"},"tokenB":{"address":"Y"}}}"#
        let pool = try JSONDecoder().decode(OrcaPool.self, from: Data(json.utf8)).data
        #expect(pool.usdPriceOfWbECX == nil)
        #expect(throws: DashboardError.self) { try MarketClient.quote(jupiter: nil, orca: pool) }
    }

    @Test func oneVenueDownOnlyDropsItsRows() async throws {
        let web = FakeDashboardWeb()
        web.on(Self.gateURL("BTC_USDT"), Self.btcGate)
        web.on(Self.gateURL("BCH_USDT"), #"[{"currency_pair":"BCH_USDT","last":"301.41","change_percentage":"-4.68","quote_volume":"4308319.7"}]"#)
        web.on(Self.gateURL("BSV_USDT"), "upstream error", status: 502)
        web.on(Self.gateURL("XEC_USDT"), #"[{"currency_pair":"XEC_USDT","last":"0.000007569","change_percentage":"-5.62","quote_volume":"20894.05"}]"#)
        web.on(Self.nonKYCURL, Self.nonKYC)
        // Jupiter and Orca unanswered → 404.
        let board = try await MarketClient(fetch: web.fetch).board()
        #expect(board.quotes.map(\.ticker) == ["BTC", "BCH", "XEC", "BTCB2"])
        #expect(board.wbECX == nil)
        #expect(board.impliedECXPrice == nil)
    }

    @Test func everyVenueDownFailsTheSection() async {
        await #expect(throws: DashboardError.self) {
            try await MarketClient(fetch: FakeDashboardWeb().fetch).board()
        }
    }

    @Test func aZeroPriceIsRejectedNotShown() throws {
        let row = try JSONDecoder().decode(NonKYCMarket.self, from: Data(#"{"lastPrice":"0"}"#.utf8))
        #expect(throws: DashboardError.self) { try MarketClient.quote(nonKYC: row) }
    }
}
