// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// The ECX price source: eCash.com's price API (`dev.ecash.com/price`).
@Suite struct EcashPriceProviderTests {
    /// Trimmed from a live response (2026-11-09). The per-market `url`s are trade-venue links the
    /// app must never surface — they are kept in the fixture precisely so the parser is shown to
    /// ignore them.
    static let live = #"{"asset":"ECX","currency":"USD","price":24.893271911813528,"method":"last price per market weighted by its 24h ECX volume; USDC/USDT = $1, BTC via Coinbase spot","volume24hEcx":10727.84228866935,"volume24hUsd":274422.16753271676,"markets":[{"venue":"orca","market":"wECX/USDC","url":"https://www.orca.so/pools/7T4xAj1ENEuPckhWqz6nJP9ZkvDnFpVF7nLbUAvSwm43","quote":"USDC","priceQuote":24.866243789025518,"priceUsd":24.866243789025518,"volume24hEcx":7560.35266957935,"volume24hUsd":187997.57261277,"weight":0.7047412206613557},{"venue":"neoxa","market":"ECX_USDC","url":"https://neoxa.exchange/trade/ECX_USDC","quote":"USDC","priceQuote":25.001,"priceUsd":25.001,"volume24hEcx":3122.5991581,"volume24hUsd":85171.59401217,"weight":0.2910742975218848}],"errors":[],"updateTime":"2026-11-09T14:13:29Z"}"#

    @Test func parsesTheLivePayload() throws {
        let quote = try EcashPriceProvider.parse(Data(Self.live.utf8))
        #expect(abs(quote.priceUSD - 24.893271911813528) < 1e-9)
        #expect(abs((quote.volume24hUSD ?? 0) - 274_422.16753271676) < 1e-6)
    }

    @Test func aBarePriceIsEnough() throws {
        let quote = try EcashPriceProvider.parse(Data(#"{"price":12.5}"#.utf8))
        #expect(quote.priceUSD == 12.5)
        #expect(quote.volume24hUSD == nil)
    }

    @Test func aZeroGarbledOrForeignPriceIsABadResponseNeverZero() {
        for payload in [#"{"asset":"ECX","currency":"USD","price":0}"#,
                        #"{"asset":"ECX","currency":"USD","price":"24.1"}"#,
                        #"{"asset":"ECX","currency":"EUR","price":24.1}"#,
                        #"{"asset":"XEC","currency":"USD","price":0.00002}"#,
                        #"{"asset":"ECX","currency":"USD"}"#,
                        "not json"] {
            #expect(throws: PriceError.self) { try EcashPriceProvider.parse(Data(payload.utf8)) }
        }
    }

    @Test func quotesUSDOnlyThroughTheInjectedFetch() async throws {
        let provider = EcashPriceProvider(fetch: { url in
            #expect(url.absoluteString == EcashPriceProvider.endpoint)
            return Data(Self.live.utf8)
        })
        #expect(provider.supportedCurrencies() == [.usd])
        #expect(abs(try await provider.spotPrice(in: .usd) - 24.893271911813528) < 1e-9)
        await #expect(throws: PriceError.unsupportedCurrency) { try await provider.spotPrice(in: .eur) }
    }

    @Test func marketQuoteIsLabelledAsEcashComWithNoChange() throws {
        let quote = MarketClient.quote(ecx: try EcashPriceProvider.parse(Data(Self.live.utf8)))
        #expect(quote.ticker == "ECX")
        #expect(quote.source == "eCash.com")
        #expect(quote.change24h == nil)   // the API carries no 24h change
        #expect(abs((quote.volume24h ?? 0) - 274_422.16753271676) < 1e-6)
    }
}
