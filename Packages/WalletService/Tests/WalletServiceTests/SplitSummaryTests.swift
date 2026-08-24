// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// The pure coin-split classifier: which spendable coins are pre-fork (shared with the other chain →
/// need splitting) vs post-fork (already safe), by confirmation height against the fork height. This
/// is the money-adjacent correctness core, so it's exhaustively unit-tested away from BDK.
final class SplitSummaryTests: XCTestCase {

    private func utxo(_ height: Int64?, _ sats: Int64, _ txid: String = "t", _ vout: Int32 = Int32(0)) -> SplitUtxo {
        SplitUtxo(height: height, sats: sats, txid: txid, vout: vout)
    }

    func testBelowForkHeightNeedsSplit() {
        // fork = 957_600 (drynet3). 957_599 is pre-fork; 957_600 is the first post-fork block.
        let s = SplitSummary.classify([utxo(957_599, 100), utxo(957_600, 200), utxo(1_000_000, 50)],
                                      forkHeight: 957_600)
        XCTAssertEqual(s.spendableSats, 350)       // total drainable
        XCTAssertEqual(s.needsSplitSats, 100)      // only the < fork coin
        XCTAssertEqual(s.needsSplitCount, 1)
    }

    func testUnconfirmedIsUnverifiedNotSafe() {
        // Unconfirmed used to be treated as "recent, therefore post-fork, therefore safe". It isn't
        // knowable: an unconfirmed coin can be the output of a replayed, non-protected spend. It
        // still doesn't drive the nudge, but it lands in `unverified` rather than vanishing.
        let s = SplitSummary.classify([utxo(nil, 500), utxo(900_000, 100)], forkHeight: 957_600)
        XCTAssertEqual(s.spendableSats, 600)
        XCTAssertEqual(s.needsSplitSats, 100)      // only the confirmed pre-fork coin
        XCTAssertEqual(s.needsSplitCount, 1)
        XCTAssertEqual(s.unverifiedSats, 500)
        XCTAssertEqual(s.unverifiedCount, 1)
    }

    /// The dangerous direction. A post-fork coin created by a spend that DIDN'T carry the replay
    /// marker exists on both chains, so height alone would call it safe and the user would be told
    /// they're separated when they aren't — their next spend moving their BTC too.
    func testKnownSharedOverridesAPostForkHeight() {
        let coin = utxo(1_000_000, 700, "abc", Int32(1))       // well above the fork
        let plain = SplitSummary.classify([coin], forkHeight: 957_600)
        XCTAssertEqual(plain.needsSplitCount, 0)               // height alone: "safe"
        XCTAssertEqual(plain.unverifiedCount, 1)               // …but only unverified

        let checked = SplitSummary.classify([coin], forkHeight: 957_600, knownShared: ["abc:1"])
        XCTAssertEqual(checked.needsSplitSats, 700)
        XCTAssertEqual(checked.needsSplitCount, 1)
        XCTAssertEqual(checked.unverifiedCount, 0)
    }

    /// The other direction: a PRE-fork coin already spent on Bitcoin can't be replayed onto — that
    /// would be a double-spend — so it needs no split despite its height saying otherwise.
    func testKnownSafeOverridesAPreForkHeight() {
        let coin = utxo(900_000, 400, "def", Int32(0))         // below the fork
        XCTAssertEqual(SplitSummary.classify([coin], forkHeight: 957_600).needsSplitCount, 1)

        let checked = SplitSummary.classify([coin], forkHeight: 957_600, knownSafe: ["def:0"])
        XCTAssertEqual(checked.needsSplitCount, 0)
        XCTAssertEqual(checked.needsSplitSats, 0)
        XCTAssertEqual(checked.unverifiedCount, 0)             // verified, not merely unchecked
        XCTAssertEqual(checked.spendableSats, 400)             // still spendable either way
    }

    /// Verified answers must not leak between coins — matching is per outpoint, and a shared txid
    /// with a different vout is a different coin.
    func testVerdictsMatchPerOutpointNotPerTxid() {
        let a = utxo(1_000_000, 100, "same", Int32(0))
        let b = utxo(1_000_000, 200, "same", Int32(1))
        let s = SplitSummary.classify([a, b], forkHeight: 957_600, knownShared: ["same:1"])
        XCTAssertEqual(s.needsSplitSats, 200)                  // only vout 1
        XCTAssertEqual(s.needsSplitCount, 1)
        XCTAssertEqual(s.unverifiedSats, 100)                  // vout 0 remains unchecked
    }

    func testNilForkHeightMeansNothingNeedsSplitting() {
        // Networks where splitting doesn't apply (Bitcoin/Signet/Thunder) → forkHeight nil.
        let s = SplitSummary.classify([utxo(100, 100), utxo(nil, 200)], forkHeight: nil)
        XCTAssertEqual(s.spendableSats, 300)
        XCTAssertEqual(s.needsSplitSats, 0)
        XCTAssertEqual(s.needsSplitCount, 0)
    }

    func testAllPreForkSumsFully() {
        let s = SplitSummary.classify([utxo(10, 100), utxo(20, 250), utxo(957_599, 1)], forkHeight: 957_600)
        XCTAssertEqual(s.spendableSats, 351)
        XCTAssertEqual(s.needsSplitSats, 351)      // every coin is pre-fork
        XCTAssertEqual(s.needsSplitCount, 3)
    }

    func testEmptyIsZero() {
        let s = SplitSummary.classify([], forkHeight: 957_600)
        XCTAssertEqual(s.spendableSats, 0)
        XCTAssertEqual(s.needsSplitSats, 0)
        XCTAssertEqual(s.needsSplitCount, 0)
    }

    func testForkHeightRegistryValues() {
        // eCash (drynet3) has a fork height; splitting doesn't apply elsewhere.
        XCTAssertEqual(NetworkRegistry.forkHeight(for: WalletNetwork.ecash), 957_600)
        XCTAssertNil(NetworkRegistry.forkHeight(for: WalletNetwork.bitcoin))
        XCTAssertNil(NetworkRegistry.forkHeight(for: WalletNetwork.signet))
        XCTAssertNil(NetworkRegistry.forkHeight(for: WalletNetwork.thunder))
    }

    // MARK: - Remote fork height (drynet rollover)

    /// The fork height is NOT a constant: drynet2/3 forked at 957,600 and drynet4 at 961,632, and the
    /// remote config repoints `.ecash` at whichever chain is live. Classification must follow the
    /// applied height, or a rollover silently mis-flags every coin confirmed between the two.
    func testRemoteForkHeightOverridesTheBundledOne() {
        let bundled = NetworkRegistry.forkHeight(for: WalletNetwork.ecash) ?? Int64(0)
        XCTAssertEqual(bundled, Int64(957_600))

        WalletManager.setRemoteForkHeightForTesting(Int64(961_632), network: WalletNetwork.ecash)
        defer { WalletManager.clearRemoteForkHeightForTesting(network: WalletNetwork.ecash) }
        XCTAssertEqual(WalletManager.effectiveForkHeight(for: WalletNetwork.ecash), Int64(961_632))

        // A coin between the two heights: pre-fork under drynet4's boundary, post-fork under the old.
        let between = [SplitUtxo(height: Int64(960_000), sats: Int64(50_000))]
        XCTAssertEqual(SplitSummary.classify(between, forkHeight: Int64(961_632)).needsSplitCount, Int32(1))
        XCTAssertEqual(SplitSummary.classify(between, forkHeight: Int64(957_600)).needsSplitCount, Int32(0))
    }

    /// A malformed payload must not be able to move the boundary to zero — that would mark every coin
    /// post-fork and silently switch splitting off.
    func testNonPositiveRemoteForkHeightIsIgnored() {
        WalletManager.setRemoteForkHeightForTesting(Int64(961_632), network: WalletNetwork.ecash)
        defer { WalletManager.clearRemoteForkHeightForTesting(network: WalletNetwork.ecash) }
        WalletManager.setRemoteForkHeightForTesting(Int64(-1), network: WalletNetwork.ecash)
        XCTAssertEqual(WalletManager.effectiveForkHeight(for: WalletNetwork.ecash), Int64(961_632))
    }
}
