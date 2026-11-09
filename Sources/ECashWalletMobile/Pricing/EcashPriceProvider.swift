// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Android/Linux Foundation, not in Foundation
#endif

/// The ECX price from **eCash.com's own price API** (`https://dev.ecash.com/price`, moved here from
/// the GeckoTerminal wECX pool read on 2026-11-09, Jake). The server quotes one USD price: the
/// last trade on every ECX market it tracks (native ECX on Neoxa, wECX on Orca), weighted by each
/// market's 24h ECX volume, with USDC/USDT taken as $1 and the BTC pair converted at Coinbase spot.
///
/// Only the headline `price` and the aggregate `volume24hUsd` are read. The per-market breakdown
/// carries trade-venue links, which the app must never show (App Review 3.1.5) — so it is not even
/// decoded. The API has no 24h change, so the quote carries none and the UI shows none. USD only.
struct EcashPriceProvider: PriceProvider {
    let id = "ecash.com"
    let displayName = "eCash.com"

    static let endpoint = "https://dev.ecash.com/price"

    private let fetch: @Sendable (URL) async throws -> Data

    init(fetch: @escaping @Sendable (URL) async throws -> Data = EcashPriceProvider.defaultFetch) {
        self.fetch = fetch
    }

    static func defaultFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: request).0
    }

    func supportedCurrencies() -> [FiatCurrency] { [.usd] }

    func spotPrice(in currency: FiatCurrency) async throws -> Double {
        guard supportedCurrencies().contains(currency) else { throw PriceError.unsupportedCurrency }
        guard let url = URL(string: Self.endpoint) else { throw PriceError.network }
        let data = try await fetch(url)
        return try Self.parse(data).priceUSD
    }

    /// What the endpoint gives us. A missing, non-positive, or non-USD price is a bad response,
    /// never a zero price.
    struct Quote: Equatable, Sendable {
        let priceUSD: Double
        let volume24hUSD: Double?
    }

    static func parse(_ data: Data) throws -> Quote {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw PriceError.badResponse
        }
        guard payload.asset == nil || payload.asset == "ECX",
              payload.currency == nil || payload.currency == "USD",
              let price = payload.price, price > 0, price.isFinite else { throw PriceError.badResponse }
        let volume = payload.volume24hUsd.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        return Quote(priceUSD: price, volume24hUSD: volume)
    }

    // Only the fields we read; `markets[]`, `method`, `errors` and `updateTime` are ignored.
    private struct Payload: Decodable {
        let asset: String?
        let currency: String?
        let price: Double?
        let volume24hUsd: Double?
    }
}
