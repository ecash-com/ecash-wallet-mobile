// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// Coin selection for Thunder sends. The fee is implicit (`value_in - value_out`), so what these
/// assert is the invariant that actually matters on-chain: inputs cover the payment plus the fee
/// exactly, and nothing is ever created out of thin air.
@Suite struct ThunderCoinSelectorTests {

    private static func utxo(_ sats: UInt64, vout: UInt32 = 0) -> ThunderPointedOutput {
        ThunderPointedOutput(
            outPoint: .regular(txid: [UInt8](repeating: 0x11, count: 32), vout: vout),
            output: ThunderOutput(address: [UInt8](repeating: 0xAB, count: 20), content: .value(sats: sats)))
    }

    /// inputs == payment + change + fee, always.
    private func expectBalances(_ selection: ThunderCoinSelection, target: UInt64) {
        #expect(selection.totalInputSats == target + selection.changeSats + selection.feeSats)
    }

    @Test func picksLargestFirstAndLeavesChange() throws {
        let selection = try ThunderCoinSelector.select(
            utxos: [Self.utxo(1_000, vout: 0), Self.utxo(50_000, vout: 1), Self.utxo(5_000, vout: 2)],
            targetSats: 10_000, satPerByte: 1)
        #expect(selection.inputs.count == 1)              // the 50k alone covers it
        #expect(selection.inputs[0].valueSats == 50_000)
        #expect(selection.changeSats > 0)
        expectBalances(selection, target: 10_000)
    }

    @Test func accumulatesUntilTheTargetIsCovered() throws {
        let selection = try ThunderCoinSelector.select(
            utxos: [Self.utxo(4_000, vout: 0), Self.utxo(4_000, vout: 1), Self.utxo(4_000, vout: 2)],
            targetSats: 9_000, satPerByte: 1)
        #expect(selection.inputs.count == 3)
        expectBalances(selection, target: 9_000)
    }

    @Test func dropsChangeThatCostsMoreThanItsWorth() throws {
        // Exact-ish funding: whatever is left is smaller than the change output would cost, so it goes
        // to the fee instead of creating a UTXO that's uneconomic to ever spend.
        let feeWithChange = ThunderCoinSelector.fee(inputCount: 1, outputCount: 2, satPerByte: 1)
        let selection = try ThunderCoinSelector.select(
            utxos: [Self.utxo(1_000 + feeWithChange + 1)], targetSats: 1_000, satPerByte: 1)
        #expect(selection.changeSats == 0)
        expectBalances(selection, target: 1_000)
        #expect(selection.feeSats > feeWithChange)        // the leftover was folded into the fee
    }

    @Test func exactFundingProducesNoChange() throws {
        let fee = ThunderCoinSelector.fee(inputCount: 1, outputCount: 2, satPerByte: 1)
        let selection = try ThunderCoinSelector.select(
            utxos: [Self.utxo(2_000 + fee)], targetSats: 2_000, satPerByte: 1)
        #expect(selection.changeSats == 0)
        expectBalances(selection, target: 2_000)
    }

    @Test func feeScalesWithRateAndNeverReachesZero() {
        let cheap = ThunderCoinSelector.fee(inputCount: 2, outputCount: 2, satPerByte: 1)
        let pricey = ThunderCoinSelector.fee(inputCount: 2, outputCount: 2, satPerByte: 10)
        #expect(pricey == cheap * 10)
        // A zero rate must still pay something — a free transaction gives miners no reason to include it.
        #expect(ThunderCoinSelector.fee(inputCount: 1, outputCount: 1, satPerByte: 0) == ThunderCoinSelector.minimumFeeSats)
    }

    @Test func insufficientFundsReportsBothAmounts() {
        do {
            _ = try ThunderCoinSelector.select(utxos: [Self.utxo(500)], targetSats: 10_000, satPerByte: 1)
            Issue.record("expected insufficientFunds")
        } catch let error as ThunderError {
            #expect(error == .insufficientFunds(neededSats: 10_000, availableSats: 500))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func fundsThatCoverTheAmountButNotTheFeeStillFail() {
        // 1_000 sats against a 1_000-sat target: the payment fits, the fee doesn't.
        #expect(throws: ThunderError.self) {
            try ThunderCoinSelector.select(utxos: [Self.utxo(1_000)], targetSats: 1_000, satPerByte: 1)
        }
    }

    // MARK: - Sweep

    @Test func sweepDrainsEverythingWithNoChange() throws {
        let utxos = [Self.utxo(1_000, vout: 0), Self.utxo(2_000, vout: 1), Self.utxo(3_000, vout: 2)]
        let selection = try ThunderCoinSelector.selectAll(utxos: utxos, satPerByte: 1)
        #expect(selection.inputs.count == 3)
        #expect(selection.changeSats == 0)
        #expect(selection.totalInputSats == 6_000)
        #expect(selection.feeSats == ThunderCoinSelector.fee(inputCount: 3, outputCount: 1, satPerByte: 1))
        #expect(selection.feeSats < selection.totalInputSats)
    }

    @Test func sweepFailsWhenTheBalanceCantCoverItsOwnFee() {
        #expect(throws: ThunderError.self) {
            try ThunderCoinSelector.selectAll(utxos: [Self.utxo(1)], satPerByte: 100)
        }
        #expect(throws: ThunderError.self) {
            try ThunderCoinSelector.selectAll(utxos: [], satPerByte: 1)
        }
    }
}
