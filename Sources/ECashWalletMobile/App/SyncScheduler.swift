// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Single-flight sync scheduling across wallets — the decision half of `AppState.sync()`, kept apart
/// so it can be tested without a real `WalletManager`.
///
/// Only one sync runs at a time (`WalletManager`'s engine cache is unlocked: one writer, CLAUDE.md §10).
/// A request for the wallet already syncing is redundant — that run is fetching current state. A
/// request for a DIFFERENT wallet means the user switched mid-sync; it's queued, not dropped, so the
/// newly selected wallet syncs the moment the current one finishes. (Dropping it left a freshly
/// selected wallet on a zeroed screen until a manual refresh.)
@MainActor
final class SyncScheduler {
    enum Admission: Equatable {
        /// Nothing running: the caller runs the sync now and must call `finish()` after.
        case run
        /// This wallet is already syncing.
        case alreadyRunning
        /// Another wallet is syncing; the selected wallet syncs when it finishes.
        case queued
    }

    private(set) var inFlightWalletId: String?
    private var syncSelectedAfterCurrent = false

    var isBusy: Bool { inFlightWalletId != nil }

    func admit(walletId: String) -> Admission {
        guard let inFlight = inFlightWalletId else {
            inFlightWalletId = walletId
            return .run
        }
        if inFlight == walletId { return .alreadyRunning }
        syncSelectedAfterCurrent = true
        return .queued
    }

    /// End the in-flight run. True when a switch queued a follow-up: sync whatever is selected NOW
    /// (it may have changed more than once while this run went).
    func finish() -> Bool {
        inFlightWalletId = nil
        let followUp = syncSelectedAfterCurrent
        syncSelectedAfterCurrent = false
        return followUp
    }
}
