// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// `supportsCoinSplit` and `NetworkRegistry.forkHeight` have to agree: a network that offers
/// splitting must have a height to classify against, and one with a fork height should be offering
/// it. Lives here rather than in the app suite because `forkHeight` is internal to WalletService —
/// raw chain constants are not bridged surface.
///
/// Why it exists: adding betanet wired its fork height (967_680) correctly, but the UI gated
/// splitting on six scattered `== .ecash` comparisons, so the height was computed and discarded.
/// Nothing failed — the feature was simply absent on the chain that needed it most.
final class CoinSplitCapabilityTests: XCTestCase {

    func testEverySplittableNetworkHasAForkHeight() {
        for net in WalletNetwork.allCases where net.supportsCoinSplit {
            XCTAssertNotNil(NetworkRegistry.forkHeight(for: net),
                            "\(net.rawValue) supports coin splitting but has no fork height to split against")
        }
    }

    func testEveryNetworkWithAForkHeightSupportsSplitting() {
        for net in WalletNetwork.allCases where NetworkRegistry.forkHeight(for: net) != nil {
            XCTAssertTrue(net.supportsCoinSplit,
                          "\(net.rawValue) has a fork height but does not offer splitting — the UI would hide it")
        }
    }

    /// The two eCash chains forked from Bitcoin at DIFFERENT heights. Sharing one would misclassify
    /// every coin in the gap between them, which is the whole failure this feature prevents.
    func testTheTwoEcashChainsHaveDistinctForkHeights() {
        let alpha = NetworkRegistry.forkHeight(for: WalletNetwork.ecash)
        let beta = NetworkRegistry.forkHeight(for: WalletNetwork.ecashBeta)
        XCTAssertEqual(alpha, 963_648)
        XCTAssertEqual(beta, 967_680)
        XCTAssertNotEqual(alpha, beta)
    }
}
