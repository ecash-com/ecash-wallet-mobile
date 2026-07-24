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
        var sweepCallCount = 0
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
    private func makeVM(balanceSats: Int64 = 1_000_000,
                        validate: @escaping (String) -> Bool = { _ in true }) -> (SendViewModel, SendRecorder) {
        let rec = SendRecorder(txToReturn: Self.pendingTx)
        let vm = SendViewModel(
            balance: Amount(sats: balanceSats),
            unitLabel: "sBTC",
            network: .signet,
            send: { address, amount, feeRate in
                rec.callCount += 1
                rec.address = address
                rec.amount = amount
                rec.feeRate = feeRate
                if let error = rec.errorToThrow { throw error }
                return rec.txToReturn
            },
            sweep: { address, feeRate in
                rec.sweepCallCount += 1
                rec.address = address
                rec.feeRate = feeRate
                if let error = rec.errorToThrow { throw error }
                return rec.txToReturn
            },
            onSent: { tx in rec.onSentTx = tx },
            authorize: { _ in rec.authCallCount += 1; return rec.authResult },
            validateAddress: validate)
        return (vm, rec)
    }

    @Test func maxTapRoutesToSweepNotSend() async {
        let (vm, rec) = makeVM()
        toAmountStep(vm)
        vm.tapMax()
        #expect(vm.isMax)
        vm.review()
        await vm.confirmSend()
        #expect(rec.sweepCallCount == 1)   // drain, not a literal-amount send
        #expect(rec.callCount == 0)
    }

    @Test func editingAmountCancelsMax() {
        let (vm, _) = makeVM()
        toAmountStep(vm)
        vm.tapMax()
        #expect(vm.isMax)
        vm.tapDigit(5)                     // user edits → back to a literal amount
        #expect(!vm.isMax)
    }

    // Drives recipient → amount. `enterAmount` taps 0.01 on the keypad (== default 1_000_000 balance).
    private func toAmountStep(_ vm: SendViewModel, address: String = "tb1qrecipient") {
        vm.addressText = address
        vm.confirmRecipient()
    }
    private func enterPointOhOne(_ vm: SendViewModel) {
        vm.tapDigit(0); vm.tapDot(); vm.tapDigit(0); vm.tapDigit(1)   // "0.01"
    }

    // MARK: - Recipient address validation (early: format + network/prefix)

    @Test func recipientValidationGatesAdvanceAndPreview() {
        // Validator stands in for BDK: only tb1… is valid for this (testnet) wallet.
        let (vm, _) = makeVM(validate: { $0.hasPrefix("tb1") })

        // Valid address → can advance, green preview, no error.
        vm.addressText = "tb1qexamplerecipientaddress"
        #expect(vm.canContinueRecipient)
        #expect(vm.recipientAddressPreview == "tb1qexamplerecipientaddress")
        #expect(!vm.recipientAddressInvalid)

        // Wrong-network / malformed → blocked, no preview, invalid flag set.
        vm.addressText = "bc1qmainnetaddresspastedbymistake"
        #expect(!vm.canContinueRecipient)
        #expect(vm.recipientAddressPreview == nil)
        #expect(vm.recipientAddressInvalid)

        // Empty → not an error (just nothing entered yet).
        vm.addressText = ""
        #expect(!vm.canContinueRecipient)
        #expect(!vm.recipientAddressInvalid)

        // BIP21 URI: the embedded address is what gets validated.
        vm.addressText = "bitcoin:tb1qexamplerecipientaddress?amount=0.001"
        #expect(vm.canContinueRecipient)
        #expect(vm.recipientAddressPreview == "tb1qexamplerecipientaddress")
        #expect(!vm.recipientAddressInvalid)
    }

    @Test func recipientWithInvalidAddressCannotConfirm() {
        let (vm, _) = makeVM(validate: { $0.hasPrefix("tb1") })
        vm.addressText = "not-an-address"
        vm.confirmRecipient()
        #expect(vm.step == .recipient)   // stays put; never reaches amount
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

    // MARK: - Navigation lock (the "popped back to the address screen mid-send" bug)

    /// A device-auth gate the test can hold open, to observe the in-flight window while the prompt
    /// is up. An actor so the non-isolated `authorize` closure touches the continuation safely.
    private actor AuthGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { self.continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// The fix for the reported bug: while the auth prompt is up, `step` is still `.reviewing` but
    /// the flow must report itself LOCKED, so a scene-phase change (iOS) / system-back (Android)
    /// can't pop the NavigationStack and walk the user back to the address screen before the send
    /// completes. Idle review is unlocked; success stays locked (Done is the only exit).
    @Test func navigationLockedThroughTheAuthPromptWindow() async {
        let gate = AuthGate()
        let rec = SendRecorder(txToReturn: Self.pendingTx)
        let vm = SendViewModel(
            balance: Amount(sats: 1_000_000),
            unitLabel: "sBTC",
            network: .signet,
            send: { _, _, _ in rec.callCount += 1; return rec.txToReturn },
            sweep: { _, _ in rec.sweepCallCount += 1; return rec.txToReturn },
            onSent: { _ in },
            authorize: { _ in await gate.wait(); return true },
            validateAddress: { _ in true })
        vm.addressText = "tb1qrecipient"
        vm.confirmRecipient()
        enterPointOhOne(vm)
        vm.review()
        #expect(!vm.isSendingLocked)        // idle review → back is allowed

        let task = Task { await vm.confirmSend() }
        var spins = 0
        while !vm.authorizing && spins < 10_000 { await Task.yield(); spins += 1 }

        #expect(vm.authorizing)             // suspended inside authorize()
        #expect(vm.step == .reviewing)      // review still on screen behind the prompt
        #expect(vm.isSendingLocked)         // …but navigation is locked — the fix
        #expect(rec.callCount == 0)         // not broadcast until auth resolves

        await gate.release()
        await task.value
        #expect(vm.step == .sent)
        #expect(!vm.authorizing)
        #expect(vm.isSendingLocked)         // success screen stays locked
    }
}
