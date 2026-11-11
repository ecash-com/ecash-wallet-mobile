// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The freshness half of `AppState.sync()`'s throttle — when each ACCOUNT last completed a sync —
/// kept apart so it can be tested without a real `WalletManager`.
///
/// Ambient sync triggers cluster: a foreground resume can fire the scene-phase sync, an app-lock
/// unlock, and a Send tap within seconds, each a full-window query for a chain that hasn't changed.
/// So a sync inside `window` of the last one is skipped (explicit user actions pass `force` and
/// bypass this). Keyed by wallet AND network (2026-11-11): under the seed-container model a network
/// switch keeps the wallet id, and a per-wallet key let eCash's fresh timestamp throttle the sync of
/// the Bitcoin account the user had just switched to — the new chain showed its on-disk numbers and
/// went straight to "idle" with no network call.
struct SyncFreshness {
    static let window: TimeInterval = 30

    private var lastSyncedAt: [String: Date] = [:]

    private static func key(walletId: String, network: WalletNetwork) -> String {
        "\(walletId)-\(network.rawValue)"
    }

    /// True when this account synced less than `window` ago — the sync can be skipped.
    func isFresh(walletId: String, network: WalletNetwork, now: Date = Date()) -> Bool {
        guard let last = lastSyncedAt[Self.key(walletId: walletId, network: network)] else { return false }
        return now.timeIntervalSince(last) < Self.window
    }

    mutating func record(walletId: String, network: WalletNetwork, at now: Date = Date()) {
        lastSyncedAt[Self.key(walletId: walletId, network: network)] = now
    }
}
