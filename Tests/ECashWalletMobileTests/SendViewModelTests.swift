// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import WalletService
@testable import ECashWalletMobile

/// The Send flow state machine — the money path. Discrete steps: recipient → amount → review →
/// broadcast. These drive the real view model through its injected `send` seam (a recorder that
/// captures args and can be programmed to throw), with no BDK / network. Every test pins a
/// behavior a bug would silently break: advancing past a step without its precondition, a wrong
/// amount, an over-balance send slipping through, a send from the wrong step, a swallowed error.
///
/// Swift Testing (not XCTest): runs on the host via `swift test` AND natively on Android via
/// `skip android test --apk`, where the real app process supplies the JNI that Fuse `@Observable`
/// needs. Recorder is `@unchecked Sendable` because the `send` seam is a non-isolated async
/// closure; tests run serially on the main actor, so the captured mutation is safe.
@MainActor
@Suite struct SendViewModelTests {

    private final class SendRecorder: @unchecked Sendable {
        var callCount = 0
        var address: String?
        var amount: Amount?
        var feeRate: FeeRate?
        var onSentTx: WalletTx?
        var errorToThrow: Error?
        var authResult = true        // device-auth gate outcome (default: approve)
        var authCallCount = 0
        let txToReturn: WalletTx
        init(txToReturn: WalletTx) { self.txToReturn = txToReturn }
    }

    private static let pendingTx = WalletTx(
        txid: "broadcasttxid", netSats: -125_000, feeSats: 200,
        confirmations: Int32(0), timestampEpochSeconds: nil, isRBF: true)

    /// Build a VM with `balance` sats and a recording send seam.
    private func makeVM(balanceSats: Int64 = 1_000_000) -> (SendViewModel, SendRecorder) {
        let rec = SendRecorder(txToReturn: Self.pendingTx)
        let vm = SendViewModel(
            balance: Amount(sats: balanceSats),
            unitLabel: "sBTC",
            networkDisplayName: "Signet",
            isMainnet: false,
            send: { address, amount, feeRate in
                rec.callCount += 1
                rec.address = address
                rec.amount = amount
                rec.feeRate = feeRate
                if let error = rec.errorToThrow { throw error }
                return rec.txToReturn
            },
            onSent: { tx in rec.onSentTx = tx },
            authorize: { _ in rec.authCallCount += 1; return rec.authResult })
        return (vm, rec)
    }

    // Drives recipient → amount. `enterAmount` taps 0.01 on the keypad (== default 1_000_000 balance).
    private func toAmountStep(_ vm: SendViewModel, address: String = "tb1qrecipient") {
        vm.addressText = address
        vm.confirmRecipient()
    }
    private func enterPointOhOne(_ vm: SendViewModel) {
        vm.tapDigit(0); vm.tapDot(); vm.tapDigit(0); vm.tapDigit(1)   // "0.01"
    }

    // MARK: - Initial / keypad

    @Test func initialState() {
        let (vm, _) = makeVM()
        #expect(vm.step == .recipient)
        #expect(vm.amountText == "")
        #expect(vm.displayAmountText == "0")   // placeholder when empty
        #expect(!vm.canContinueRecipient)      // no address yet
    }

    @Test func keypadBuildsParseableAmount() {
        let (vm, _) = makeVM()
        enterPointOhOne(vm)
        #expect(vm.amountText == "0.01")
        #expect(vm.displayAmountText == "0.01")
        #expect(vm.amount?.sats == Int64(1_000_000))
    }

    @Test func tapMaxFillsBalanceAndDoesNotExceedIt() {
        let (vm, _) = makeVM(balanceSats: 1_000_000)
        vm.tapMax()
        #expect(vm.amount?.sats == Int64(1_000_000))
        #expect(!vm.amountExceedsBalance)   // equal is not "exceeds"
    }

    // MARK: - Step 1: recipient

    @Test func canContinueRecipientNeedsAParseableAddress() {
        let (vm, _) = makeVM()
        #expect(!vm.canContinueRecipient)          // empty
        vm.addressText = "   "
        #expect(!vm.canContinueRecipient)          // whitespace → BIP21.parse nil
        vm.addressText = "tb1qexample"
        #expect(vm.canContinueRecipient)
    }

    @Test func confirmRecipientAdvancesToAmount() {
        let (vm, _) = makeVM()
        vm.addressText = "tb1qrecipient"
        vm.confirmRecipient()
        #expect(vm.step == .amount)
        #expect(vm.reviewAddress == "tb1qrecipient")
    }

    @Test func recipientRejectsUnparseableAddress() {
        let (vm, _) = makeVM()
        vm.addressText = ""        // BIP21.parse returns nil
        vm.confirmRecipient()
        #expect(vm.step == .recipient)   // stays put
    }

    @Test func confirmRecipientParsesBIP21AndFillsAmountFromURI() {
        let (vm, _) = makeVM(balanceSats: 100_000_000)
        vm.addressText = "bitcoin:tb1quri?amount=0.5&label=Coffee"
        vm.confirmRecipient()
        #expect(vm.step == .amount)
        #expect(vm.reviewAddress == "tb1quri")     // scheme + query stripped to the bare address
        #expect(vm.amountText == "0.50000000")     // amount pre-filled from the URI
    }

    @Test func typedAmountSurvivesBIP21WithAmount() {
        let (vm, _) = makeVM(balanceSats: 100_000_000)
        vm.tapDigit(1)   // user typed "1" before pasting
        vm.addressText = "bitcoin:tb1quri?amount=0.5"
        vm.confirmRecipient()
        #expect(vm.amountText == "1")   // the URI does not overwrite a typed amount
    }

    // MARK: - Step 2: amount → review

    @Test func reviewAdvancesWithValidAmount() {
        let (vm, _) = makeVM()
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        #expect(vm.step == .reviewing)
        #expect(vm.reviewAddress == "tb1qrecipient")
        #expect(vm.reviewAmount.sats == Int64(1_000_000))
    }

    @Test func reviewBlockedWithoutAmount() {
        let (vm, _) = makeVM()
        toAmountStep(vm)
        #expect(!vm.canReview)        // zero amount
        vm.review()
        #expect(vm.step == .amount)   // stays on amount
    }

    @Test func amountExceedingBalanceBlocksReview() {
        let (vm, _) = makeVM(balanceSats: 1_000_000)
        toAmountStep(vm)
        vm.tapDigit(0); vm.tapDot(); vm.tapDigit(0); vm.tapDigit(2)   // 0.02 > 0.01 balance
        #expect(vm.amountExceedsBalance)
        #expect(!vm.canReview)
        vm.review()
        #expect(vm.step == .amount)   // an over-balance amount must never reach review
    }

    @Test func reviewIsNoOpOutsideAmountStep() {
        let (vm, _) = makeVM()
        vm.review()                   // from .recipient
        #expect(vm.step == .recipient)
    }

    // MARK: - Step navigation

    @Test func backStepsAmountToRecipient() {
        let (vm, _) = makeVM()
        toAmountStep(vm)
        vm.back()
        #expect(vm.step == .recipient)
    }

    @Test func backStepsReviewToAmount() {
        let (vm, _) = makeVM()
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        #expect(vm.step == .reviewing)
        vm.back()
        #expect(vm.step == .amount)
    }

    // MARK: - Step 3: confirmSend()

    @Test func confirmSendBroadcastsWithExactReviewedArgs() async {
        let (vm, rec) = makeVM()
        toAmountStep(vm)
        vm.tier = .fast
        enterPointOhOne(vm)
        vm.review()
        await vm.confirmSend()

        #expect(vm.step == .sent)
        #expect(rec.callCount == 1)
        #expect(rec.address == "tb1qrecipient")
        #expect(rec.amount?.sats == Int64(1_000_000))
        #expect(rec.feeRate?.satPerVByte == Int64(5))    // the selected fast tier's rate
        #expect(rec.onSentTx?.txid == "broadcasttxid")   // broadcast tx handed to onSent
    }

    @Test func confirmSendMapsWalletErrorToUserMessage() async {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.insufficientFunds
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        await vm.confirmSend()

        #expect(vm.step == .failed(WalletError.insufficientFunds.userMessage))
        #expect(rec.onSentTx == nil)   // a failed broadcast must not insert a pending tx
    }

    @Test func confirmSendMapsUnknownErrorToGenericMessage() async {
        struct Boom: Error {}
        let (vm, rec) = makeVM()
        rec.errorToThrow = Boom()
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        await vm.confirmSend()

        #expect(vm.step == .failed("Couldn't send. Please try again."))
        #expect(rec.onSentTx == nil)
    }

    @Test func confirmSendIsNoOpOutsideReviewingStep() async {
        let (vm, rec) = makeVM()
        await vm.confirmSend()        // from .recipient
        #expect(vm.step == .recipient)
        #expect(rec.callCount == 0)   // broadcast reachable only from the reviewed step
    }

    @Test func deniedAuthBlocksTheBroadcast() async {
        let (vm, rec) = makeVM()
        rec.authResult = false        // user cancels Face ID / passcode
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        await vm.confirmSend()

        #expect(rec.authCallCount == 1)
        #expect(rec.callCount == 0)        // never broadcast without authorization (§7)
        #expect(vm.step == .reviewing)     // stays on review so the user can retry
        #expect(rec.onSentTx == nil)
    }

    @Test func confirmSendAuthorizesBeforeBroadcasting() async {
        let (vm, rec) = makeVM()
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        await vm.confirmSend()
        #expect(rec.authCallCount == 1)    // auth gate runs on the happy path too
        #expect(vm.step == .sent)
    }

    @Test func canRetryToAmountAfterFailure() async {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.broadcastFailed
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        await vm.confirmSend()
        if case .failed = vm.step {} else { Issue.record("expected failed") }
        vm.back()
        #expect(vm.step == .amount)   // failure → back to amount to edit
    }

    @Test func retryResendsAfterFailureThenSucceeds() async {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.broadcastFailed
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        await vm.confirmSend()
        if case .failed = vm.step {} else { Issue.record("expected failed") }

        rec.errorToThrow = nil          // network recovered
        await vm.retry()
        #expect(vm.step == .sent)
        #expect(rec.callCount == 2)     // re-broadcast with the same reviewed args
        #expect(rec.address == "tb1qrecipient")
    }

    @Test func retryIsNoOpUnlessFailed() async {
        let (vm, rec) = makeVM()
        toAmountStep(vm)
        enterPointOhOne(vm)
        vm.review()
        await vm.retry()                // from .reviewing, not .failed
        #expect(rec.callCount == 0)
        #expect(vm.step == .reviewing)
    }
}
