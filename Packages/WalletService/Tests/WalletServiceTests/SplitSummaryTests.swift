// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// The pure coin-split classifier: which spendable coins are pre-fork (shared with the other chain →
/// need splitting) vs post-fork (already safe), by confirmation height against the fork height. This
/// is the money-adjacent correctness core, so it's exhaustively unit-tested away from BDK.
final class SplitSummaryTests: XCTestCase {

    private func utxo(_ height: Int64?, _ sats: Int64) -> SplitUtxo { SplitUtxo(height: height, sats: sats) }

    func testBelowForkHeightNeedsSplit() {
        // fork = 957_600 (drynet3). 957_599 is pre-fork; 957_600 is the first post-fork block.
        let s = SplitSummary.classify([utxo(957_599, 100), utxo(957_600, 200), utxo(1_000_000, 50)],
                                      forkHeight: 957_600)
        XCTAssertEqual(s.spendableSats, 350)       // total drainable
        XCTAssertEqual(s.needsSplitSats, 100)      // only the < fork coin
        XCTAssertEqual(s.needsSplitCount, 1)
    }

    func testUnconfirmedIsPostForkSafe() {
        // Unconfirmed (height nil) = recent = post-fork; never counts as needing a split.
        let s = SplitSummary.classify([utxo(nil, 500), utxo(900_000, 100)], forkHeight: 957_600)
        XCTAssertEqual(s.spendableSats, 600)
        XCTAssertEqual(s.needsSplitSats, 100)      // only the confirmed pre-fork coin
        XCTAssertEqual(s.needsSplitCount, 1)
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
}
