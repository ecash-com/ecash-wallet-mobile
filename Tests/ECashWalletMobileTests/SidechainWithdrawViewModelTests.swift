// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

@MainActor
@Suite struct SidechainWithdrawViewModelTests {
    final class Calls: @unchecked Sendable {
        var withdrawals: [(address: String, script: [UInt8], amount: Int64, mainFee: Int64, feeRate: Int64)] = []
        var done: [WalletTx] = []
        var authorizeReasons: [String] = []
    }

    /// The only "valid mainchain address" the fake BDK parse accepts, and its script.
    private static let goodAddress = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    private static let goodScript: [UInt8] = [0x00, 0x14, 0xab]

    private func makeVM(approve: Bool = true, calls: Calls = Calls(), spendable: Int64 = 1_000_000,
                        withdrawError: Error? = nil,
                        timing: SidechainWithdrawViewModel.Timing? = .init(minimumBlocks: 13_151, expiryBlocks: 26_300,
                                                                            batchInProgress: nil)) -> SidechainWithdrawViewModel {
        SidechainWithdrawViewModel(
            sidechainTitle: "Thunder", sidechainNetwork: .thunder,
            mainchain: .ecashBeta, mainchainDisplayName: "Betanet", unitLabel: "ECX",
            spendable: Amount(sats: spendable),
            scriptPubKey: { $0 == Self.goodAddress ? Self.goodScript : nil },
            withdraw: { address, script, amount, mainFee, feeRate in
                if let withdrawError { throw withdrawError }
                calls.withdrawals.append((address, script, amount.sats, mainFee.sats, feeRate.satPerVByte))
                return WalletTx(txid: "wd", netSats: -(amount.sats + mainFee.sats + 300), feeSats: 300,
                                confirmations: 0, timestampEpochSeconds: nil, isRBF: false,
                                sidechainWithdrawalAddress: address)
            },
            authorize: { reason in calls.authorizeReasons.append(reason); return approve },
            onDone: { calls.done.append($0) },
            loadTiming: { timing })
    }

    private func fill(_ vm: SidechainWithdrawViewModel, address: String = goodAddress, amount: String = "0.0004") {
        vm.addressText = address
        vm.amountText = amount
    }

    @Test func mainchainFeeDefaultsToBitWindowsTenThousandSats() {
        let vm = makeVM()
        #expect(vm.mainFee == Amount(sats: 10_000))
    }

    @Test func onlyAValidMainchainAddressCanBeReviewed() {
        let vm = makeVM()
        fill(vm, address: "tb1qnotonthismainchain")
        #expect(vm.isAddressInvalid)
        #expect(!vm.canReview)
        fill(vm)
        #expect(!vm.isAddressInvalid)
        #expect(vm.canReview)
    }

    @Test func amountRulesCoverDustTheMainFeeAndTheBalance() {
        let vm = makeVM(spendable: 50_000)
        fill(vm, amount: "0.00000545")                // 545 sats < 546
        #expect(vm.amountProblem == .belowMinimum)
        fill(vm, amount: "0.0004")
        vm.mainFeeText = "0"
        #expect(vm.amountProblem == .noMainFee)
        vm.mainFeeText = "0.0002"                      // 40,000 + 20,000 > 50,000
        #expect(vm.amountProblem == .exceedsBalance)
        vm.mainFeeText = "0.0001"                      // 40,000 + 10,000 == 50,000
        #expect(vm.amountProblem == .none)
        #expect(vm.totalBeforeSidechainFee == Amount(sats: 50_000))
    }

    /// The wait must be acknowledged on the review step — every time, not carried over from an edit.
    @Test func confirmingRequiresTheAcknowledgement() async {
        let calls = Calls()
        let vm = makeVM(calls: calls)
        fill(vm)
        vm.review()
        #expect(vm.phase == .reviewing)
        #expect(!vm.canConfirm)
        await vm.confirm()
        #expect(calls.withdrawals.isEmpty)

        vm.acknowledged = true
        vm.back()
        vm.review()
        #expect(!vm.acknowledged)                      // reset by re-review
    }

    @Test func confirmedWithdrawalPassesTheValidatedScriptAndFees() async {
        let calls = Calls()
        let vm = makeVM(calls: calls)
        fill(vm)
        vm.tier = .fast
        vm.review()
        vm.acknowledged = true
        await vm.confirm()

        #expect(calls.withdrawals.count == 1)
        let w = calls.withdrawals[0]
        #expect(w.address == Self.goodAddress)
        #expect(w.script == Self.goodScript)
        #expect(w.amount == 40_000 && w.mainFee == 10_000)
        #expect(w.feeRate == SendViewModel.FeeTier.fast.feeRate.satPerVByte)
        #expect(calls.done.map(\.txid) == ["wd"])
        #expect(calls.authorizeReasons == ["Authorize withdrawal to Betanet"])
        if case .done(let tx) = vm.phase { #expect(tx.isSidechainWithdrawal) } else { Issue.record("not done") }
    }

    @Test func declinedAuthWithdrawsNothing() async {
        let calls = Calls()
        let vm = makeVM(approve: false, calls: calls)
        fill(vm)
        vm.review()
        vm.acknowledged = true
        await vm.confirm()
        #expect(calls.withdrawals.isEmpty)
        #expect(vm.phase == .reviewing)
    }

    @Test func thunderErrorsSurfaceTheirPlainMessage() async {
        let vm = makeVM(withdrawError: ThunderError.insufficientFunds(neededSats: 1, availableSats: 0))
        fill(vm)
        vm.review()
        vm.acknowledged = true
        await vm.confirm()
        #expect(vm.errorMessage == ThunderError.insufficientFunds(neededSats: 1, availableSats: 0).userMessage)
        vm.retry()
        #expect(vm.phase == .reviewing)
    }

    @Test func timingComesFromTheEnforcerOrStaysUnknown() async {
        let known = makeVM()
        await known.loadTimingIfNeeded()
        #expect(known.minimumBlocks == 13_151 && known.expiryBlocks == 26_300)
        #expect(known.batchInProgress == nil)

        let unknown = makeVM(timing: nil)
        await unknown.loadTimingIfNeeded()
        #expect(unknown.minimumBlocks == nil && unknown.expiryBlocks == nil)   // never a guessed number
    }

    /// A sidechain forms a new batch only when none is pending — the review must say so when one is.
    @Test func aBatchAlreadyBeingVotedOnIsSurfaced() async {
        let batch = SidechainWithdrawViewModel.BatchInProgress(votes: 156, votesNeeded: 13_151, blocksUntilExpiry: 25_940)
        let vm = makeVM(timing: .init(minimumBlocks: 13_151, expiryBlocks: 26_300, batchInProgress: batch))
        await vm.loadTimingIfNeeded()
        #expect(vm.batchInProgress == batch)
    }

    @Test func pickingAMainchainWalletFillsItsUnusedAddress() async {
        let vm = SidechainWithdrawViewModel(
            sidechainTitle: "Thunder", sidechainNetwork: .thunder, mainchain: .ecashBeta,
            mainchainDisplayName: "Betanet", unitLabel: "ECX", spendable: Amount(sats: 1),
            scriptPubKey: { _ in nil }, withdraw: { _, _, _, _, _ in fatalError() },
            authorize: { _ in true }, onDone: { _ in }, loadTiming: { nil },
            destinations: [SendViewModel.Destination(id: "m1", label: "Checking", balance: .unknown)],
            addressForDestination: { id in id == "m1" ? Self.goodAddress : "" })
        await vm.useDestination(vm.destinations[0])
        #expect(vm.addressText == Self.goodAddress)
        #expect(vm.destinationError == nil)
    }
}
