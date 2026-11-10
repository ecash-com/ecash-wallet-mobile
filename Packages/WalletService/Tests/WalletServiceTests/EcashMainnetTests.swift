// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// The real eCash mainnet case (`.ecashMainnet`): its compiled consensus values, and the two gates
/// that decide when it is offered and when it becomes the default (`EcashMainnetLaunch`).
///
/// The values are checked against the node source (github.com/ecash-com/bitcoin master, read
/// 2026-10-21), not against each other: fork height `consensus.EcashHeight = 973728`,
/// `OP_DRIVECHAIN = OP_NOP8` (0xb7), and replay protection `nLockTime == LOCKTIME_THRESHOLD - 2`.
final class EcashMainnetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EcashMainnetLaunch.resetForTesting(offered: false)
        WalletManager.clearRemoteForkHeightForTesting(network: WalletNetwork.ecashMainnet)
    }

    override func tearDown() {
        EcashMainnetLaunch.resetForTesting(offered: false)
        WalletManager.clearRemoteForkHeightForTesting(network: WalletNetwork.ecashMainnet)
        super.tearDown()
    }

    // MARK: - Identity and derivation

    /// The rawValue is persisted in the wallet store and enforced by `check_network` — fixed forever.
    func testRawValueIsStable() {
        XCTAssertEqual(WalletNetwork.ecashMainnet.rawValue, "ecashMainnet")
        XCTAssertEqual(WalletNetwork(rawValue: "ecashMainnet"), WalletNetwork.ecashMainnet)
        // And the test forks keep theirs: betanet is never repurposed.
        XCTAssertEqual(WalletNetwork(rawValue: "ecashBeta"), WalletNetwork.ecashBeta)
        XCTAssertEqual(WalletNetwork(rawValue: "ecash"), WalletNetwork.ecash)
    }

    func testDerivesExactlyLikeTheTestForksAndBitcoin() {
        let p = NetworkRegistry.params(for: WalletNetwork.ecashMainnet)
        XCTAssertEqual(p.coinType, Int32(0))
        XCTAssertEqual(p.addressHRP, "bc")
        XCTAssertEqual(p.unitLabel, "ECX")
        XCTAssertEqual(p.subUnitLabel, "szat")
        XCTAssertEqual(p.defaultBackendKind, "esplora")
        XCTAssertTrue(WalletNetwork.ecashMainnet.sharesKeys(with: WalletNetwork.ecashBeta))
        XCTAssertTrue(WalletNetwork.ecashMainnet.sharesKeys(with: WalletNetwork.ecash))
        XCTAssertTrue(WalletNetwork.ecashMainnet.sharesKeys(with: WalletNetwork.bitcoin))
        XCTAssertFalse(WalletNetwork.ecashMainnet.sharesKeys(with: WalletNetwork.signet))
    }

    func testIsRealMoney() {
        XCTAssertTrue(WalletNetwork.ecashMainnet.isMainnet)
        XCTAssertTrue(WalletNetwork.bitcoin.isMainnet)
        XCTAssertFalse(WalletNetwork.ecashBeta.isMainnet)
        XCTAssertFalse(WalletNetwork.ecash.isMainnet)
    }

    func testSupportsCoinSplitting() {
        XCTAssertTrue(WalletNetwork.ecashMainnet.supportsCoinSplit)
    }

    // MARK: - Consensus values (compiled, never from config)

    /// `LOCKTIME_THRESHOLD - 2`. The test forks' `- 1` is NOT valid on the real chain: there it reads
    /// as a block height ~500M blocks out and the tx is rejected as non-final.
    func testReplayMarkerIsOneBelowTheTestForks() {
        XCTAssertEqual(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.ecashMainnet), UInt32(499_999_998))
        XCTAssertEqual(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.ecashBeta), UInt32(499_999_999))
        XCTAssertEqual(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.ecash), UInt32(499_999_999))
        XCTAssertNil(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.bitcoin))
    }

    func testForkHeightIsTheNodesEcashHeight() {
        XCTAssertEqual(NetworkRegistry.forkHeight(for: WalletNetwork.ecashMainnet), Int64(973_728))
        XCTAssertNotEqual(NetworkRegistry.forkHeight(for: WalletNetwork.ecashMainnet), NetworkRegistry.forkHeight(for: WalletNetwork.ecashBeta))
    }

    func testDrivechainOpcodeIsNop8() {
        XCTAssertEqual(Drivechain.opcode(for: WalletNetwork.ecashMainnet), UInt8(0xb7))
    }

    /// Alphanet (`.ecash`) was retired 2026-10-26, betanet (`.ecashBeta`) and Thunder betanet
    /// (`.thunder`) 2026-10-30: none is offered, but each persisted rawValue must keep decoding so
    /// existing wallets on those chains load.
    func testRetiredNetworksAreNotOfferedButStillDecode() {
        for retired in [WalletNetwork.ecash, WalletNetwork.ecashBeta, WalletNetwork.thunder] {
            XCTAssertFalse(WalletNetwork.selectable.contains(retired), "\(retired) must not be creatable")
            XCTAssertEqual(WalletNetwork(rawValue: retired.rawValue), retired)
            XCTAssertTrue(WalletNetwork.allCases.contains(retired))
        }
        XCTAssertNotEqual(WalletNetwork.ecash, WalletNetwork.ecashMainnet)
    }

    // MARK: - Launch gates

    /// Picker order (Jake, 2026-10-29): the real fork first, then Bitcoin, then L2L Signet. The
    /// default is `currentEcash` (also the real fork). The order is the same with and without a
    /// fetched config. Betanet and Thunder betanet were retired from the picker 2026-10-30.
    func testPickerOrderPutsTheRealForkFirst() {
        // Thunder mainnet trails as the offered SIDECHAIN (2026-11-10): the switcher nests it under
        // eCash; `mainchainsForNewWallets` drops it from create/import.
        let expected = [WalletNetwork.ecashMainnet, WalletNetwork.bitcoin, WalletNetwork.signet, WalletNetwork.thunderMainnet]
        XCTAssertEqual(WalletNetwork.selectable, expected)
        EcashMainnetLaunch.resetForTesting(offered: true)
        XCTAssertEqual(WalletNetwork.selectable, expected)
    }

    /// Since 1.4.6 build 44 the offer is compiled in (the config published the entry 2026-10-26): with NO
    /// config ever fetched, mainnet is in the picker, first, and is the default for new wallets and
    /// imports — none of it waits for a fetch or for the fork (Jake, 2026-10-29). The fork latch is
    /// independent: closed until a tip past the height is recorded, and it steers nothing.
    func testOfferedFirstAndDefaultBeforeAnyConfigOrFork() {
        XCTAssertTrue(EcashMainnetLaunch.offeredInThisBuild)
        XCTAssertTrue(EcashMainnetLaunch.isOffered)
        XCTAssertEqual(WalletNetwork.selectable.first, WalletNetwork.ecashMainnet)
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)
        XCTAssertFalse(EcashMainnetLaunch.isDefault)
        XCTAssertTrue(EcashMainnetLaunch.recordObservedTip(height: Int64(999_999)))
        XCTAssertTrue(EcashMainnetLaunch.isDefault)
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)
    }

    func testAFetchedConfigChangesNothingAboutTheOfferOrTheLatch() {
        EcashMainnetLaunch.resetForTesting(offered: true)
        XCTAssertTrue(EcashMainnetLaunch.isOffered)
        XCTAssertTrue(WalletNetwork.selectable.contains(WalletNetwork.ecashMainnet))
        XCTAssertFalse(WalletNetwork.selectable.contains(WalletNetwork.ecashBeta), "betanet retired 2026-10-30")
        XCTAssertFalse(EcashMainnetLaunch.isDefault)
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)
    }

    func testTheForkLatchFlipsOnlyAtTheForkHeight() {
        EcashMainnetLaunch.resetForTesting(offered: true)
        XCTAssertFalse(EcashMainnetLaunch.recordObservedTip(height: Int64(973_727)))
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)

        XCTAssertTrue(EcashMainnetLaunch.recordObservedTip(height: Int64(973_728)))
        XCTAssertTrue(EcashMainnetLaunch.isDefault)
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)
        // Latched: a later, lower (or repeated) observation doesn't flip it back, and reports no change.
        XCTAssertFalse(EcashMainnetLaunch.recordObservedTip(height: Int64(973_728)))
        XCTAssertFalse(EcashMainnetLaunch.recordObservedTip(height: Int64(1)))
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)
    }

    /// The config's `fork_height` for the mainnet entry is the one the gate compares against.
    func testTheConfigsForkHeightWins() {
        EcashMainnetLaunch.resetForTesting(offered: true)
        WalletManager.setRemoteForkHeightForTesting(Int64(980_000), network: WalletNetwork.ecashMainnet)
        XCTAssertEqual(EcashMainnetLaunch.forkHeight, Int64(980_000))
        XCTAssertFalse(EcashMainnetLaunch.recordObservedTip(height: Int64(973_728)))
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)
        XCTAssertTrue(EcashMainnetLaunch.recordObservedTip(height: Int64(980_000)))
        XCTAssertEqual(WalletNetwork.currentEcash, WalletNetwork.ecashMainnet)
    }

    func testEverySelectableNetworkResolvesWhileMainnetIsOffered() {
        EcashMainnetLaunch.resetForTesting(offered: true)
        for network in WalletNetwork.selectable {
            let kind = NetworkRegistry.params(for: network).defaultBackendKind
            XCTAssertNotNil(WalletBackend.Kind.from(kind), "\(network.rawValue)")
        }
    }
}
