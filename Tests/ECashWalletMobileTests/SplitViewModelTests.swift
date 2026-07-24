// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// The split-coins flow state machine. Money-critical invariants: the drain is gated behind device
/// auth (no drain on cancel), the split closure gets the chosen fee, and a failure surfaces a message
/// without marking done. The view model never sees an address (the engine derives the destination).
@MainActor
@Suite struct SplitViewModelTests {

    private final class Rec: @unchecked Sendable {
        var splitCount = 0
        var feeRate: FeeRate?
        var errorToThrow: Error?
        var onDoneTx: WalletTx?
        var authResult = true
        var authCount = 0
    }

    private static let tx = WalletTx(txid: "split", netSats: -1_000_000, feeSats: 2,
                                     confirmations: 0, timestampEpochSeconds: nil, isRBF: true)

    private func makeVM(spendable: Int64 = 1_000_000, needsCount: Int32 = 1) -> (SplitViewModel, Rec) {
        let rec = Rec()
        let vm = SplitViewModel(
            summary: SplitSummary(spendableSats: spendable, needsSplitSats: spendable, needsSplitCount: needsCount),
            unitLabel: "ECX",
            networkDisplayName: "Drynet3",
            split: { feeRate in
                rec.splitCount += 1
                rec.feeRate = feeRate
                if let e = rec.errorToThrow { throw e }
                return Self.tx
            },
            onDone: { tx in rec.onDoneTx = tx },
            authorize: { _ in rec.authCount += 1; return rec.authResult })
        return (vm, rec)
    }

    @Test func confirmAuthorizesThenDrainsWithChosenFee() async {
        let (vm, rec) = makeVM()
        vm.tier = .fast
        await vm.confirm()
        #expect(rec.authCount == 1)
        #expect(rec.splitCount == 1)
        #expect(rec.feeRate == SendViewModel.FeeTier.fast.feeRate)
        #expect(rec.onDoneTx?.txid == "split")
        #expect(vm.phase == .done)
    }

    @Test func deniedAuthDoesNotDrain() async {
        let (vm, rec) = makeVM()
        rec.authResult = false
        await vm.confirm()
        #expect(rec.authCount == 1)
        #expect(rec.splitCount == 0)     // NO drain when auth is denied — funds untouched
        #expect(vm.phase == .intro)
    }

    @Test func failureSurfacesMessageAndDoesNotComplete() async {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.broadcastFailed
        await vm.confirm()
        #expect(rec.splitCount == 1)
        #expect(rec.onDoneTx == nil)     // not marked done on failure
        if case .failed = vm.phase {} else { Issue.record("expected .failed, got \(vm.phase)") }
        #expect(vm.errorMessage != nil)
    }

    @Test func amountReflectsSpendableAndNeedsCount() {
        let (vm, _) = makeVM(spendable: 500_000, needsCount: 3)
        #expect(vm.amount == Amount(sats: 500_000))
        #expect(vm.needsSplitCount == 3)
    }

    @Test func confirmIsNoOpOnceDone() async {
        let (vm, rec) = makeVM()
        await vm.confirm()
        #expect(vm.phase == .done)
        await vm.confirm()               // second call must not drain again
        #expect(rec.splitCount == 1)
    }
}
