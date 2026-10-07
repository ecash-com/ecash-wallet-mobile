// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Android/Linux Foundation (same as Pricing)
#endif

/// The one network seam every dashboard client shares. Injected so each client is unit-testable
/// against recorded responses with no server, and returns `(Data, status)` rather than `URLResponse`
/// to stay `Sendable` — the same shape `ThunderEsploraClient` and the price providers use.
typealias DashboardFetch = @Sendable (URL) async throws -> (Data, Int)

/// A dashboard source failed. Never shown verbatim: a card that fails just reads "Unavailable"
/// (`docs/dashboard-plan.md` §3.4). The detail is for logs and tests.
enum DashboardError: Error, Equatable {
    case http(Int)
    case malformed(String)
}

enum DashboardHTTP {
    static func live(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// GET `url`, throwing on anything but a 2xx.
    static func get(_ url: URL, using fetch: DashboardFetch) async throws -> Data {
        let (data, status) = try await fetch(url)
        guard (200..<300).contains(status) else { throw DashboardError.http(status) }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL, using fetch: DashboardFetch,
                                     route: String) async throws -> T {
        let data = try await get(url, using: fetch)
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw DashboardError.malformed(route)
        }
        return value
    }

    /// `base` + `path`, tolerating a trailing slash on the base.
    static func url(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path) else { throw DashboardError.malformed(path) }
        return url
    }
}
