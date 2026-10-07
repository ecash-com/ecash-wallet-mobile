// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
@testable import ECashWalletMobile

/// A canned web for the dashboard clients: URL string → (body, status). Unknown URLs answer 404, so a
/// test fails loudly if a client asks for something unexpected.
final class FakeDashboardWeb: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Data, Int)] = [:]
    private(set) var requested: [String] = []

    func on(_ url: String, _ body: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        routes[url] = (Data(body.utf8), status)
    }

    var fetch: DashboardFetch {
        { [self] url in respond(to: url) }
    }

    private func respond(to url: URL) -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        requested.append(url.absoluteString)
        return routes[url.absoluteString] ?? (Data("not found".utf8), 404)
    }
}

/// An in-memory `DashboardCaching`.
final class MemoryDashboardCache: DashboardCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (Data, Int64)] = [:]

    func load<T: Codable>(_ type: T.Type, key: String) -> (value: T, at: Int64)? {
        lock.lock(); defer { lock.unlock() }
        guard let (data, at) = store[key], let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        return (value, at)
    }

    func save<T: Codable>(_ value: T, at: Int64, key: String) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(value) { store[key] = (data, at) }
    }

    var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.keys).sorted()
    }
}
