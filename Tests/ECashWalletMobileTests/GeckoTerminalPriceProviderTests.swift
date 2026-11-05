// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// The ECX price source: GeckoTerminal's keyless pool endpoint for wECX / USDC on Orca.
@Suite struct GeckoTerminalPriceProviderTests {
    /// Trimmed from a live response (2026-11-05); numbers are strings in GeckoTerminal's JSON:API.
    static let live = #"{"data":{"id":"solana_7T4xAj1ENEuPckhWqz6nJP9ZkvDnFpVF7nLbUAvSwm43","type":"pool","attributes":{"base_token_price_usd":"31.4254965429256755308997751009072806146432156","name":"wECX / USDC","price_change_percentage":{"m5":"0","h1":"-0.2","h6":"-1.1","h24":"-4.132"},"volume_usd":{"m5":"0","h1":"100.5","h6":"2000.1","h24":"124349.759230667"},"reserve_in_usd":"919910.1802"}}}"#

    @Test func parsesTheLivePayload() throws {
        let pool = try GeckoTerminalPriceProvider.parse(Data(Self.live.utf8))
        #expect(abs(pool.priceUSD - 31.4254965) < 1e-6)
        #expect(pool.change24h == -4.132)
        #expect(abs((pool.volume24hUSD ?? 0) - 124_349.759230667) < 1e-6)
        #expect(abs((pool.liquidityUSD ?? 0) - 919_910.1802) < 1e-4)
    }

    @Test func missingWindowsStillYieldAPrice() throws {
        let minimal = #"{"data":{"attributes":{"base_token_price_usd":"12.5"}}}"#
        let pool = try GeckoTerminalPriceProvider.parse(Data(minimal.utf8))
        #expect(pool.priceUSD == 12.5)
        #expect(pool.change24h == nil)
        #expect(pool.volume24hUSD == nil)
    }

    @Test func aZeroOrGarbledPriceIsABadResponseNeverZero() {
        for payload in [#"{"data":{"attributes":{"base_token_price_usd":"0"}}}"#,
                        #"{"data":{"attributes":{"base_token_price_usd":"n/a"}}}"#,
                        "not json"] {
            #expect(throws: PriceError.self) { try GeckoTerminalPriceProvider.parse(Data(payload.utf8)) }
        }
    }

    @Test func quotesUSDOnlyThroughTheInjectedFetch() async throws {
        let provider = GeckoTerminalPriceProvider(fetch: { url in
            #expect(url.absoluteString == GeckoTerminalPriceProvider.endpoint)
            return Data(Self.live.utf8)
        })
        #expect(provider.supportedCurrencies() == [.usd])
        #expect(abs(try await provider.spotPrice(in: .usd) - 31.4254965) < 1e-6)
        await #expect(throws: PriceError.unsupportedCurrency) { try await provider.spotPrice(in: .eur) }
    }

    @Test func marketQuoteIsLabelledAsOrca() throws {
        let quote = MarketClient.quote(pool: try GeckoTerminalPriceProvider.parse(Data(Self.live.utf8)))
        #expect(quote.ticker == "ECX")
        #expect(quote.source == "Orca")
        #expect(quote.change24h == -4.132)
    }
}
