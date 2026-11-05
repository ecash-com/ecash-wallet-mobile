// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Android/Linux Foundation, not in Foundation
#endif

/// The ECX price, from the **wECX / USDC pool on Orca (Solana)** via GeckoTerminal's keyless public
/// API (decided with Jake 2026-11-05). This is the same pool CoinMarketCap's "eCash (ECX)" page
/// quotes — its contract is the pool's base token — so there is no more independent source today.
///
/// What it is, honestly: a wrapped ECX token on another chain in a pool with under $1M of
/// liquidity, not an exchange rate for native ECX. Everywhere the number shows, the source is
/// labelled ("wECX · Orca"). USD only: the pool is quoted in USDC. Keyless and no swap links, per
/// the Dashboard rules (no CoinGecko key, App Review 3.1.5).
struct GeckoTerminalPriceProvider: PriceProvider {
    let id = "geckoterminal"
    let displayName = "wECX · Orca"

    /// The wECX / USDC Orca pool.
    static let poolAddress = "7T4xAj1ENEuPckhWqz6nJP9ZkvDnFpVF7nLbUAvSwm43"
    static let endpoint = "https://api.geckoterminal.com/api/v2/networks/solana/pools/\(poolAddress)"

    private let fetch: @Sendable (URL) async throws -> Data

    init(fetch: @escaping @Sendable (URL) async throws -> Data = GeckoTerminalPriceProvider.defaultFetch) {
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

    /// What the pool endpoint gives us. Numbers arrive as strings; anything missing or non-positive
    /// is a bad response, never a zero price.
    struct PoolQuote: Equatable, Sendable {
        let priceUSD: Double
        let change24h: Double?
        let volume24hUSD: Double?
        let liquidityUSD: Double?
    }

    static func parse(_ data: Data) throws -> PoolQuote {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw PriceError.badResponse
        }
        let a = envelope.data.attributes
        guard let price = Double(a.baseTokenPriceUsd), price > 0 else { throw PriceError.badResponse }
        return PoolQuote(priceUSD: price,
                         change24h: a.priceChangePercentage?.h24.flatMap(Double.init),
                         volume24hUSD: a.volumeUsd?.h24.flatMap(Double.init),
                         liquidityUSD: a.reserveInUsd.flatMap(Double.init))
    }

    // GeckoTerminal's JSON:API envelope — only the fields we read.
    private struct Envelope: Decodable {
        let data: Pool
    }
    private struct Pool: Decodable {
        let attributes: Attributes
    }
    private struct Attributes: Decodable {
        let baseTokenPriceUsd: String
        let priceChangePercentage: Windows?
        let volumeUsd: Windows?
        let reserveInUsd: String?

        enum CodingKeys: String, CodingKey {
            case baseTokenPriceUsd = "base_token_price_usd"
            case priceChangePercentage = "price_change_percentage"
            case volumeUsd = "volume_usd"
            case reserveInUsd = "reserve_in_usd"
        }
    }
    private struct Windows: Decodable {
        let h24: String?
    }
}
