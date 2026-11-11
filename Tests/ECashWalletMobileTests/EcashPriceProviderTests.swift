// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// The ECX price source: eCash.com's price API (`dev.ecash.com/price`).
@Suite struct EcashPriceProviderTests {
    /// Trimmed from a live response (2026-11-11, the day the API gained `price24hAgo` +
    /// `priceChange24hPercent`). The per-market `url`s are trade-venue links the app must never
    /// surface — they are kept in the fixture precisely so the parser is shown to ignore them.
    static let live = #"{"asset":"ECX","currency":"USD","price":27.45574264817553,"method":"last price per market weighted by its 24h ECX volume; USDC/USDT = $1, BTC via Coinbase spot","volume24hEcx":6370.950425339994,"volume24hUsd":173173.56088474582,"markets":[{"venue":"orca","market":"wECX/USDC","url":"https://www.orca.so/pools/7T4xAj1ENEuPckhWqz6nJP9ZkvDnFpVF7nLbUAvSwm43","quote":"USDC","priceQuote":27.60069674900895,"priceUsd":27.60069674900895,"volume24hEcx":4516.681431579993,"volume24hUsd":124663.554504919,"weight":0.7089493921684306},{"venue":"neoxa","market":"ECX_USDC","url":"https://neoxa.exchange/trade/ECX_USDC","quote":"USDC","priceQuote":26.99042349,"priceUsd":26.99042349,"volume24hEcx":1693.95710201,"volume24hUsd":44163.26703471,"weight":0.26588766022607996}],"errors":[],"updateTime":"2026-11-11T17:55:04.892Z","price24hAgo":21.3623,"priceChange24hPercent":28.52}"#

    @Test func parsesTheLivePayload() throws {
        let quote = try EcashPriceProvider.parse(Data(Self.live.utf8))
        #expect(abs(quote.priceUSD - 27.45574264817553) < 1e-9)
        #expect(abs((quote.volume24hUSD ?? 0) - 173_173.56088474582) < 1e-6)
        #expect(quote.change24hPercent == 28.52)
    }

    /// The response before 2026-11-11 had no change field; a missing or garbled one is simply absent,
    /// never a bad response and never a fake 0 %.
    @Test func aBarePriceIsEnough() throws {
        let quote = try EcashPriceProvider.parse(Data(#"{"price":12.5}"#.utf8))
        #expect(quote.priceUSD == 12.5)
        #expect(quote.volume24hUSD == nil)
        #expect(quote.change24hPercent == nil)
        let garbled = try EcashPriceProvider.parse(Data(#"{"price":12.5,"priceChange24hPercent":"28.5"}"#.utf8))
        #expect(garbled.priceUSD == 12.5)
        #expect(garbled.change24hPercent == nil)
        let negative = try EcashPriceProvider.parse(Data(#"{"price":12.5,"priceChange24hPercent":-3.1}"#.utf8))
        #expect(negative.change24hPercent == -3.1)
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
        #expect(abs(try await provider.spotPrice(in: .usd) - 27.45574264817553) < 1e-9)
        await #expect(throws: PriceError.unsupportedCurrency) { try await provider.spotPrice(in: .eur) }
    }

    @Test func marketQuoteIsLabelledAsEcashComWithTheAPIsChange() throws {
        let quote = MarketClient.quote(ecx: try EcashPriceProvider.parse(Data(Self.live.utf8)))
        #expect(quote.ticker == "ECX")
        #expect(quote.source == "eCash.com")
        #expect(quote.change24h == 28.52)   // the API's own `priceChange24hPercent`, in percent like every other row
        #expect(abs((quote.volume24h ?? 0) - 173_173.56088474582) < 1e-6)
        let bare = MarketClient.quote(ecx: try EcashPriceProvider.parse(Data(#"{"price":12.5}"#.utf8)))
        #expect(bare.change24h == nil)      // pre-2026-11-11 shape: the card and row omit the change
    }
}
