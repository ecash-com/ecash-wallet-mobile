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
    static let dexURL = "https://api.dexscreener.com/latest/dex/pairs/solana/\(MarketClient.orcaPool)"

    static let btcGate = #"[{"currency_pair":"BTC_USDT","last":"83237.6","change_percentage":"-3.73","quote_volume":"881200598.5151595"}]"#
    static let nonKYC = #"{"symbol":"BTCB2/USDT","lastPrice":"674.64","yesterdayPrice":"678.37","volume":"333.1556"}"#
    static let dex = #"{"schemaVersion":"1.0.0","pairs":[{"chainId":"solana","dexId":"orca","priceUsd":"2.56","priceChange":{"h24":-18.8},"volume":{"h24":4521.23},"liquidity":{"usd":62241.99}}]}"#

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

    @Test func dexScreenerGivesWbECX() throws {
        let response = try JSONDecoder().decode(DexScreenerResponse.self, from: Data(Self.dex.utf8))
        let quote = try MarketClient.quote(dexScreener: response)
        #expect(quote.ticker == "wbECX")
        #expect(quote.price == 2.56)
        #expect(quote.change24h == -18.8)
        let board = MarketBoard(quotes: [], wbECX: quote)
        #expect(board.impliedECXPrice == 2.56 * 50)
    }

    @Test func oneVenueDownOnlyDropsItsRows() async throws {
        let web = FakeDashboardWeb()
        web.on(Self.gateURL("BTC_USDT"), Self.btcGate)
        web.on(Self.gateURL("BCH_USDT"), #"[{"currency_pair":"BCH_USDT","last":"301.41","change_percentage":"-4.68","quote_volume":"4308319.7"}]"#)
        web.on(Self.gateURL("BSV_USDT"), "upstream error", status: 502)
        web.on(Self.gateURL("XEC_USDT"), #"[{"currency_pair":"XEC_USDT","last":"0.000007569","change_percentage":"-5.62","quote_volume":"20894.05"}]"#)
        web.on(Self.nonKYCURL, Self.nonKYC)
        // DexScreener unanswered → 404.
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
