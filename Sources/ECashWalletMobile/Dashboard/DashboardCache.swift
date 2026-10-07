// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The last good value of each card, so a cold start shows numbers instantly instead of skeletons.
/// Keyed by network AND section: after the config flips the dashboard to mainnet, betanet's cache is
/// simply never read again — it can't appear under the mainnet header.
protocol DashboardCaching: Sendable {
    func load<T: Codable>(_ type: T.Type, key: String) -> (value: T, at: Int64)?
    func save<T: Codable>(_ value: T, at: Int64, key: String)
}

/// JSON files in the Caches directory — public market/chain data only, nothing about the user's
/// wallets, so losing it (the OS may purge Caches) only costs a skeleton on next launch.
struct FileDashboardCache: DashboardCaching {
    private struct Entry<T: Codable>: Codable {
        let value: T
        let at: Int64
    }

    private var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("dashboard", isDirectory: true)
    }

    func load<T: Codable>(_ type: T.Type, key: String) -> (value: T, at: Int64)? {
        guard let file = directory?.appendingPathComponent("\(key).json"),
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry<T>.self, from: data) else { return nil }
        return (entry.value, entry.at)
    }

    func save<T: Codable>(_ value: T, at: Int64, key: String) {
        guard let directory, let data = try? JSONEncoder().encode(Entry(value: value, at: at)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
