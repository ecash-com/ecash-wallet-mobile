// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Throttles how often the remote endpoints config is re-fetched, honoring the payload's
/// `refresh_after_seconds`. The app calls `refreshRemoteEndpoints()` on launch AND on every
/// foreground resume; without a throttle, frequent app switching would hammer the endpoint. This
/// records the last successful fetch time + the interval the server asked for, and reports whether
/// a new fetch is due — so between-fetch resumes are cheap and rely on last-known-good state.
///
/// Injectable `now`/`defaults` keep it unit-testable without real time or global state.
enum RemoteConfigRefreshPolicy {
    /// Used until the server tells us otherwise, and as a floor so a bad/zero value can't cause a
    /// fetch-every-resume loop.
    static let defaultInterval: TimeInterval = 600
    static let minInterval: TimeInterval = 60

    private static let lastFetchKey = "remote.config.lastFetchAt"
    private static let intervalKey = "remote.config.refreshInterval"

    /// True if enough time has passed since the last successful fetch (or if none has happened yet).
    static func isDue(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let last = defaults.object(forKey: lastFetchKey) as? Double
        guard let last else { return true }   // never fetched → due
        let interval = storedInterval(defaults: defaults)
        return now.timeIntervalSince1970 - last >= interval
    }

    /// Record a successful fetch at `now`, storing the server's requested interval (clamped to a
    /// sane floor) for the next `isDue` check.
    static func recordFetch(interval seconds: Int?, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: lastFetchKey)
        if let seconds {
            defaults.set(max(Double(seconds), minInterval), forKey: intervalKey)
        }
    }

    /// Reset throttle state (tests / full reset) — the next `isDue` returns true.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastFetchKey)
        defaults.removeObject(forKey: intervalKey)
    }

    private static func storedInterval(defaults: UserDefaults) -> TimeInterval {
        let stored = defaults.object(forKey: intervalKey) as? Double ?? defaultInterval
        return max(stored, minInterval)
    }
}
