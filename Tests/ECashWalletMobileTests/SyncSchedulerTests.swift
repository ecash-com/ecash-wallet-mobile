// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import ECashWalletMobile

/// Wallet switching mid-sync. The bug this pins: switching while another wallet synced DROPPED the new
/// wallet's sync, leaving it on a zeroed screen until a manual refresh.
@MainActor @Suite struct SyncSchedulerTests {

    @Test func anIdleSchedulerRunsTheSync() {
        let scheduler = SyncScheduler()
        #expect(scheduler.admit(walletId: "a") == .run)
        #expect(scheduler.isBusy)
        #expect(scheduler.finish() == false)
        #expect(!scheduler.isBusy)
    }

    @Test func aSecondRequestForTheSameWalletIsCoalesced() {
        let scheduler = SyncScheduler()
        _ = scheduler.admit(walletId: "a")
        #expect(scheduler.admit(walletId: "a") == .alreadyRunning)
        #expect(scheduler.finish() == false)   // nothing to follow up
    }

    @Test func switchingMidSyncQueuesAFollowUp() {
        let scheduler = SyncScheduler()
        _ = scheduler.admit(walletId: "a")
        #expect(scheduler.admit(walletId: "b") == .queued)
        #expect(scheduler.admit(walletId: "c") == .queued)   // switched twice: still ONE follow-up
        #expect(scheduler.finish() == true)
        #expect(!scheduler.isBusy)
        // The follow-up is a fresh run, and leaves nothing queued behind it.
        #expect(scheduler.admit(walletId: "c") == .run)
        #expect(scheduler.finish() == false)
    }
}
