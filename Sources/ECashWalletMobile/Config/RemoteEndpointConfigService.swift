// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Android/Linux Foundation (same as Pricing)
#endif

/// Fetches the remote `wallet-endpoints/v1.json` config and applies its per-network backend defaults.
///
/// **Best-effort and fail-safe:** any failure — no network, a non-200, malformed JSON, an
/// unsupported schema — is swallowed and simply leaves the previously applied (last-known-good) or
/// bundled endpoints in place. It never throws to the caller and never blocks the wallet. The
/// applied values persist in `WalletManager` (UserDefaults), so a later offline launch still uses
/// the last-known-good remote endpoints before this even runs.
///
/// Only backend URLs/kinds are applied — never consensus/derivation params (Golden Rule §1/§4).
struct RemoteEndpointConfigService {
    /// Production config URL — the L2L-hosted network config. Overridable for dev via the
    /// `WALLET_ENDPOINTS_URL` env var (mirrors the CoinNews dev-endpoint override).
    static let productionURL = "https://drivechain.dev/config"

    let url: URL
    private let fetch: @Sendable (URL) async throws -> Data

    init(url: URL? = nil, fetch: @escaping @Sendable (URL) async throws -> Data = RemoteEndpointConfigService.defaultFetch) {
        let resolved = url
            ?? ProcessInfo.processInfo.environment["WALLET_ENDPOINTS_URL"].flatMap { URL(string: $0) }
            ?? URL(string: Self.productionURL)!
        self.url = resolved
        self.fetch = fetch
    }

    static func defaultFetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        // URLSession does NOT throw on HTTP error status (a 404 returns the error-page body). Reject
        // non-2xx explicitly so a not-live / broken endpoint fails cleanly here → the caller falls
        // back to last-known-good / bundled, instead of trying to parse an error page.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Fetch + parse. Returns the validated config, or `nil` on any failure (no network, non-200,
    /// malformed JSON, unsupported schema). The caller applies `resolvedPrimaryBackends()` — kept
    /// separate so the (off-actor) fetch returns a plain `Sendable` value and the main actor does the
    /// `WalletManager` mutation, with no cross-actor closure.
    func load() async -> RemoteEndpointConfig? {
        guard let data = try? await fetch(url) else { return nil }        // no network / bad response
        return RemoteEndpointConfig.parse(data)                          // nil on malformed / bad schema
    }
}
