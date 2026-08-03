// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Remembers when this device first observed each Thunder txid, per wallet.
///
/// **This exists only because the node can't tell us a transaction's height.** Without a height there
/// is no chronological key to sort history by, and an Activity list in arbitrary order reads as
/// broken. First-seen is a local approximation: exactly right for a wallet in daily use (we see each
/// transaction as it happens) and arbitrary-but-*stable* for a freshly restored wallet, where the
/// whole history arrives in one sync and shares a timestamp.
///
/// Stable matters: without persistence the order would reshuffle on every launch, which looks worse
/// than being wrong consistently.
///
/// **Delete this the moment the node reports heights** — it's scaffolding for a missing field, and
/// real heights are strictly better in every case.
protocol ThunderFirstSeenStoring {
    func firstSeen(walletId: String) -> [String: Int64]
    /// Stamp any txid we haven't recorded yet. Existing entries are never overwritten — the first
    /// sighting is the whole point.
    func record(txids: Set<String>, walletId: String, now: Int64)
}

struct UserDefaultsThunderFirstSeenStore: ThunderFirstSeenStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ walletId: String) -> String { "thunder.firstSeen.\(walletId)" }

    // Stored as a JSON string, NOT a plist dictionary: `UserDefaults.dictionary(forKey:)` is
    // unavailable in Skip's Foundation on Android, and only the Android build surfaces that.
    func firstSeen(walletId: String) -> [String: Int64] {
        guard let json = defaults.string(forKey: key(walletId)),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return decoded
    }

    func record(txids: Set<String>, walletId: String, now: Int64) {
        var current = firstSeen(walletId: walletId)
        var changed = false
        for txid in txids where current[txid] == nil {
            current[txid] = now
            changed = true
        }
        guard changed,
              let data = try? JSONEncoder().encode(current),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: key(walletId))
    }
}

/// In-memory variant for tests.
final class InMemoryThunderFirstSeenStore: ThunderFirstSeenStoring, @unchecked Sendable {
    private var byWallet: [String: [String: Int64]] = [:]

    init() {}

    func firstSeen(walletId: String) -> [String: Int64] { byWallet[walletId] ?? [:] }

    func record(txids: Set<String>, walletId: String, now: Int64) {
        var current = byWallet[walletId] ?? [:]
        for txid in txids where current[txid] == nil { current[txid] = now }
        byWallet[walletId] = current
    }
}
