// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// `WalletTx` derived-value logic — the fee-rate computation used by the transaction detail
/// screen, plus the direction/confirmation helpers. Pure logic, runs on both platforms.
final class WalletTxTests: XCTestCase {

    private func tx(netSats: Int64 = -400_000, feeSats: Int64? = 200, confirmations: Int32 = 3,
                    blockHeight: Int64? = 196_842, vsize: Int64? = 141) -> WalletTx {
        WalletTx(txid: "t", netSats: netSats, feeSats: feeSats, confirmations: confirmations,
                 timestampEpochSeconds: nil, isRBF: false, blockHeight: blockHeight, vsize: vsize)
    }

    func testFeeRateIsFeeOverVsize() {
        // 200 sats / 141 vB = 1.4184… sat/vB
        let rate = tx(feeSats: 200, vsize: 141).feeRatePerVByte()
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 200.0 / 141.0, accuracy: 0.0001)
    }

    func testFeeRateExactWhenDivisible() {
        XCTAssertEqual(tx(feeSats: 282, vsize: 141).feeRatePerVByte()!, 2.0, accuracy: 0.0001)
    }

    func testFeeRateNilWhenFeeUnknown() {
        XCTAssertNil(tx(feeSats: nil, vsize: 141).feeRatePerVByte())
    }

    func testFeeRateNilWhenVsizeUnknown() {
        XCTAssertNil(tx(feeSats: 200, vsize: nil).feeRatePerVByte())
    }

    func testFeeRateNilWhenVsizeZero() {
        // Guard against divide-by-zero rather than returning inf/NaN.
        XCTAssertNil(tx(feeSats: 200, vsize: 0).feeRatePerVByte())
    }

    func testDirectionAndConfirmation() {
        XCTAssertTrue(tx(netSats: 200_000).isReceived)
        XCTAssertFalse(tx(netSats: -200_000).isReceived)
        XCTAssertTrue(tx(confirmations: 1).isConfirmed)
        XCTAssertFalse(tx(confirmations: 0).isConfirmed)
    }

    // MARK: - Self-transfer (split / self-sweep / CoinNews post)

    /// A coin split drains every UTXO back to the same wallet, so the only value that leaves is the
    /// fee: netSats == -feeSats. This is the flag the UI needs, because the usual "amount minus fee"
    /// cancels to zero here and renders a real split as 0.00000000.
    func testSplitToSelfIsASelfTransfer() {
        XCTAssertTrue(tx(netSats: -200, feeSats: 200).isSelfTransfer)
    }

    /// An ordinary send moves value to someone else on top of the fee — never a self-transfer.
    func testOrdinarySendIsNotASelfTransfer() {
        XCTAssertFalse(tx(netSats: -400_000, feeSats: 200).isSelfTransfer)
    }

    func testReceiveIsNotASelfTransfer() {
        XCTAssertFalse(tx(netSats: 500_000, feeSats: nil).isSelfTransfer)
        XCTAssertFalse(tx(netSats: 0, feeSats: 0).isSelfTransfer)
    }

    /// Without a fee we can't prove nothing else left the wallet, so don't claim it.
    func testUnknownFeeIsNotASelfTransfer() {
        XCTAssertFalse(tx(netSats: -200, feeSats: nil).isSelfTransfer)
    }

    /// The regression this exists to prevent: fee-netting a self-transfer yields exactly zero.
    func testFeeNettingWouldZeroOutASelfTransfer() {
        let split = tx(netSats: -200, feeSats: 200)
        let netted = abs(split.netSats) - (split.feeSats ?? 0)
        XCTAssertEqual(netted, 0)                 // what the UI used to show
        XCTAssertEqual(abs(split.netSats), 200)   // what it shows now: the fee
    }

    /// The amount a split actually moved lives in `receivedSats`, not `netSats` — netSats is only
    /// the fee, so without this the UI has no way to say what happened. Real numbers from the first
    /// on-chain drynet3 split: 230,854 sats in, 386 fee, 230,468 landed at the new address.
    func testSelfTransferCarriesTheMovedAmount() {
        let split = WalletTx(txid: "s", netSats: -386, feeSats: 386, confirmations: 1,
                             timestampEpochSeconds: nil, isRBF: true, receivedSats: 230_468)
        XCTAssertTrue(split.isSelfTransfer)
        XCTAssertEqual(split.receivedSats, 230_468)
        XCTAssertEqual(abs(split.netSats), 386)   // net is the fee — not what the row should show
    }

    /// Older/foreign txs may have no received value; the flag must not depend on it.
    func testSelfTransferFlagIsIndependentOfReceivedSats() {
        XCTAssertTrue(tx(netSats: -200, feeSats: 200).isSelfTransfer)   // receivedSats defaults nil
    }
}
