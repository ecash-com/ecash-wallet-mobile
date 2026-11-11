// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// The sync throttle is per ACCOUNT. The bug this pins (2026-11-11): keyed per wallet, a network
/// switch — which keeps the wallet id — inherited the previous chain's fresh timestamp and skipped
/// the new chain's sync.
@Suite struct SyncFreshnessTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aRecentSyncOfTheSameAccountIsFresh() {
        var freshness = SyncFreshness()
        #expect(!freshness.isFresh(walletId: "w", network: .ecashMainnet, now: t0))
        freshness.record(walletId: "w", network: .ecashMainnet, at: t0)
        #expect(freshness.isFresh(walletId: "w", network: .ecashMainnet, now: t0.addingTimeInterval(5)))
        #expect(!freshness.isFresh(walletId: "w", network: .ecashMainnet, now: t0.addingTimeInterval(SyncFreshness.window)))
    }

    @Test func switchingNetworkInTheSameWalletIsNeverThrottledByTheOtherChain() {
        var freshness = SyncFreshness()
        freshness.record(walletId: "w", network: .ecashMainnet, at: t0)
        #expect(!freshness.isFresh(walletId: "w", network: .bitcoin, now: t0.addingTimeInterval(1)))
        #expect(!freshness.isFresh(walletId: "w", network: .signet, now: t0.addingTimeInterval(1)))
        // …and syncing Bitcoin doesn't disturb eCash's own timestamp.
        freshness.record(walletId: "w", network: .bitcoin, at: t0.addingTimeInterval(10))
        #expect(freshness.isFresh(walletId: "w", network: .ecashMainnet, now: t0.addingTimeInterval(20)))
        #expect(!freshness.isFresh(walletId: "w", network: .ecashMainnet, now: t0.addingTimeInterval(31)))
    }

    @Test func anotherWalletOnTheSameChainIsIndependent() {
        var freshness = SyncFreshness()
        freshness.record(walletId: "a", network: .ecashMainnet, at: t0)
        #expect(!freshness.isFresh(walletId: "b", network: .ecashMainnet, now: t0.addingTimeInterval(1)))
    }
}
