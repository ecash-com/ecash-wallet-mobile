// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// Fiat pricing: currency formatting, Bitfinex response parsing, the per-network provider registry,
/// and sats→fiat conversion. All offline — `BitfinexPriceProvider` takes an injectable fetch and
/// `PriceService` takes an injectable provider resolver, so nothing here touches the network.
///
/// Swift Testing (not XCTest) — runs on the host via `swift test` and natively on Android.
@MainActor
@Suite struct PricingTests {

    private struct StubProvider: PriceProvider {
        let id = "stub"
        let displayName = "Stub"
        let price: Double
        func supportedCurrencies() -> [FiatCurrency] { FiatCurrency.allCases }
        func spotPrice(in currency: FiatCurrency) async throws -> Double { price }
    }

    // MARK: - Currency formatting

    @Test func usdFormatsWithSymbolGroupingAndTwoDecimals() {
        #expect(FiatCurrency.usd.format(50_000) == "$50,000.00")
        #expect(FiatCurrency.usd.format(1234.5) == "$1,234.50")
    }

    @Test func jpyFormatsWithNoMinorUnits() {
        #expect(FiatCurrency.jpy.format(5_000_000) == "¥5,000,000")
    }

    // MARK: - Bitfinex parsing (LAST_PRICE is index 6)

    @Test func parsesLastPriceFromTickerArray() throws {
        let json = "[57000,1.1,57001,2.2,-100,-0.01,57005.5,123.4,58000,56000]".data(using: .utf8)!
        #expect(try BitfinexPriceProvider.parseLastPrice(json) == 57005.5)
    }

    @Test func rejectsShortTickerArray() {
        let json = "[1,2,3]".data(using: .utf8)!
        #expect(throws: PriceError.badResponse) { try BitfinexPriceProvider.parseLastPrice(json) }
    }

    @Test func rejectsNonPositivePrice() {
        let json = "[0,0,0,0,0,0,0,0,0,0]".data(using: .utf8)!
        #expect(throws: PriceError.badResponse) { try BitfinexPriceProvider.parseLastPrice(json) }
    }

    @Test func spotPriceUsesInjectedFetch() async throws {
        let provider = BitfinexPriceProvider(fetch: { _ in
            "[1,1,1,1,1,1,42000.0,1,1,1]".data(using: .utf8)!
        })
        let price = try await provider.spotPrice(in: .usd)
        #expect(price == 42000.0)
    }

    // MARK: - Per-network provider registry

    @Test func bitcoinIsPricedTestnetsAreNot() {
        #expect(PriceProviderRegistry.supportsPricing(.bitcoin))
        #expect(PriceProviderRegistry.supportsPricing(.ecashMainnet))   // wECX on Orca, USD only (2026-11-05)
        #expect(!PriceProviderRegistry.supportsPricing(.signet))
    }

    // MARK: - PriceService conversion + gating

    @Test func convertsSatsToFiatAtTheQuotedPrice() async {
        let service = PriceService(resolveProvider: { _ in StubProvider(price: 50_000) })
        service.currency = .usd
        await service.refresh(for: .bitcoin)
        #expect(service.fiatString(forSats: 100_000_000) == "$50,000.00")  // 1 BTC
        #expect(service.fiatString(forSats: 50_000_000) == "$25,000.00")   // 0.5 BTC
    }

    @Test func clearsQuoteForNetworksWithoutAProvider() async {
        let service = PriceService(resolveProvider: { net in net == .bitcoin ? StubProvider(price: 1) : nil })
        service.currency = .usd
        await service.refresh(for: .bitcoin)
        #expect(service.fiatString(forSats: 100_000_000) != nil)
        await service.refresh(for: .signet)   // no provider → quote cleared
        #expect(service.fiatString(forSats: 100_000_000) == nil)
    }

    @Test func noFiatBeforeAnyFetch() {
        let service = PriceService(resolveProvider: { _ in StubProvider(price: 1) })
        #expect(service.fiatString(forSats: 100_000_000) == nil)
    }
}
