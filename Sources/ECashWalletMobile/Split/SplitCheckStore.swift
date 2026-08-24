// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Remembers what a Bitcoin check said about each outpoint, per wallet.
///
/// Worth caching because the answer is stable for the case that matters: an outpoint Bitcoin has
/// never seen will never start existing there. The one direction it can change is `shared` →
/// `chainSpecific`, when someone later spends the Bitcoin side — which only ever makes the coin
/// safer, so a stale `shared` errs toward telling the user to split something they no longer need
/// to. That's the harmless direction, and re-running the check corrects it.
///
/// Deliberately only stores decided answers. `.unknown` is never cached: it describes our failure to
/// reach a backend, not a property of the coin, and persisting it would make a temporary outage look
/// like a settled fact.
///
/// Keyed by `walletId` per Golden Rule §5 — nothing crosses between wallets, and removing a wallet
/// clears its entry.
struct SplitCheckStore {
    private static let key = "split.check.results"
    private static let checkedAtKey = "split.check.checkedAt"

    private var all: [String: [String: String]] {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.key),
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
            else { return [:] }
            return decoded
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }

    /// Stored as a JSON string rather than a dictionary because `UserDefaults.dictionary(forKey:)`
    /// isn't available in Skip's Foundation.
    func results(walletId: String) -> [String: SplitCoinStatus] {
        var out: [String: SplitCoinStatus] = [:]
        for (key, raw) in all[walletId] ?? [:] {
            if let status = SplitCoinStatus(rawValue: raw), status != .unknown { out[key] = status }
        }
        return out
    }

    /// Merge in a completed check. Existing entries for outpoints not in `results` are kept — a
    /// partial check (some outpoints timed out) must not erase what earlier runs established.
    func merge(_ results: [String: SplitCoinStatus], walletId: String) {
        var everything = all
        var forWallet = everything[walletId] ?? [:]
        for (key, status) in results where status != .unknown {
            forWallet[key] = status.rawValue
        }
        everything[walletId] = forWallet
        all = everything
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970),
                                  forKey: "\(Self.checkedAtKey).\(walletId)")
    }

    /// When this wallet was last checked (epoch seconds), or nil if never. Drives the "checked X ago"
    /// line — results are a point-in-time answer, so their age is part of the answer.
    func lastCheckedEpochSeconds(walletId: String) -> Int? {
        let stored = UserDefaults.standard.integer(forKey: "\(Self.checkedAtKey).\(walletId)")
        return stored > 0 ? stored : nil
    }

    /// Purge on wallet removal (Golden Rule §5).
    func forget(walletId: String) {
        var everything = all
        everything.removeValue(forKey: walletId)
        all = everything
        UserDefaults.standard.removeObject(forKey: "\(Self.checkedAtKey).\(walletId)")
    }

    /// Outpoint keys by verdict, in the shape `splitSummary(knownShared:knownSafe:)` wants.
    func partitioned(walletId: String) -> (shared: [String], safe: [String]) {
        var shared: [String] = []
        var safe: [String] = []
        for (key, status) in results(walletId: walletId) {
            if status == .shared { shared.append(key) } else if status == .chainSpecific { safe.append(key) }
        }
        return (shared, safe)
    }
}
