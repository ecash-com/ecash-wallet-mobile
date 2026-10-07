// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One dashboard card's state. Cards load and fail independently (`docs/dashboard-plan.md` §3.4), so
/// each carries its own value, age and last-attempt outcome rather than sharing a screen-wide state.
struct DashboardSection<Value: Equatable & Sendable>: Equatable, Sendable {
    /// The last good value — from this session or the on-disk cache. Kept through failed refreshes:
    /// a number that's a few minutes old beats an empty card.
    var value: Value?
    /// When `value` was fetched (epoch seconds).
    var updatedAt: Int64?
    var isLoading = false
    /// The most recent attempt failed. With a value: show it, marked stale. Without: "Unavailable".
    var lastAttemptFailed = false
    /// When the last attempt started, success or not — paces retries after a failure.
    var lastAttemptAt: Int64?

    enum Display: Equatable {
        /// Nothing yet and still trying — skeleton rows.
        case loading
        /// Nothing to show and the source failed.
        case unavailable
        /// A value; `stale` when the latest refresh failed.
        case ready(stale: Bool)
    }

    var display: Display {
        if value != nil { return .ready(stale: lastAttemptFailed) }
        return lastAttemptFailed ? .unavailable : .loading
    }

    /// Whether a refresh is due under `cadence` seconds. Paces by the last ATTEMPT, so a source that's
    /// down is retried once per cadence, not on every 60-second tick.
    func isDue(now: Int64, cadence: Int64) -> Bool {
        guard let last = lastAttemptAt else { return true }
        return now - last >= cadence
    }
}
