// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// "Copy to network" state machine. Invariants: nothing is copied without device auth, a network
/// the wallet is already on can't be chosen, and a failure
/// surfaces a message and leaves the choice in place for a retry.
@MainActor
@Suite struct CopyWalletViewModelTests {

    private final class Rec: @unchecked Sendable {
        var copied: [WalletNetwork] = []
        var authResult = true
        var authCount = 0
        var errorToThrow: Error?
    }

    private func makeVM(targets: [CopyWalletViewModel.Target]) -> (CopyWalletViewModel, Rec) {
        let rec = Rec()
        let vm = CopyWalletViewModel(
            walletLabel: "Savings",
            targets: targets,
            copy: { network in
                if let e = rec.errorToThrow { throw e }
                rec.copied.append(network)
            },
            authorize: { _ in rec.authCount += 1; return rec.authResult })
        return (vm, rec)
    }

    private static let beta = CopyWalletViewModel.Target(network: .ecashBeta, existingWalletId: nil)
    private static let bitcoin = CopyWalletViewModel.Target(network: .bitcoin, existingWalletId: nil)

    @Test func confirmWithoutAChoiceDoesNothing() async {
        let (vm, rec) = makeVM(targets: [Self.beta])
        await vm.confirm()
        #expect(rec.authCount == 0)
        #expect(rec.copied.isEmpty)
    }

    @Test func chooseThenConfirmAuthorizesAndCopies() async {
        let (vm, rec) = makeVM(targets: [Self.beta, Self.bitcoin])
        vm.choose(Self.beta)
        await vm.confirm()
        #expect(rec.authCount == 1)
        #expect(rec.copied == [.ecashBeta])
        #expect(vm.errorMessage == nil)
    }

    @Test func deniedAuthCopiesNothing() async {
        let (vm, rec) = makeVM(targets: [Self.beta])
        rec.authResult = false
        vm.choose(Self.beta)
        await vm.confirm()
        #expect(rec.authCount == 1)
        #expect(rec.copied.isEmpty)
        #expect(!vm.isBusy)
    }

    @Test func anAddedNetworkCannotBeChosen() async {
        let added = CopyWalletViewModel.Target(network: .ecashBeta, existingWalletId: "wallet-2")
        let (vm, rec) = makeVM(targets: [added, Self.bitcoin])
        #expect(added.isAdded)
        vm.choose(added)
        #expect(vm.selected == nil)          // never staged for a second copy
        await vm.confirm()
        #expect(rec.copied.isEmpty)
        #expect(rec.authCount == 0)
    }

    @Test func failureShowsTheMessageAndKeepsTheChoice() async {
        let (vm, rec) = makeVM(targets: [Self.beta])
        rec.errorToThrow = WalletError.copyMismatch
        vm.choose(Self.beta)
        await vm.confirm()
        #expect(vm.errorMessage == WalletError.copyMismatch.userMessage)
        #expect(vm.selected == .ecashBeta)
        // Choosing again clears the error; a retry then succeeds.
        rec.errorToThrow = nil
        vm.choose(Self.beta)
        #expect(vm.errorMessage == nil)
        await vm.confirm()
        #expect(rec.copied == [.ecashBeta])
    }

    @Test func realMoneyWarningFollowsTheChoice() {
        let (vm, _) = makeVM(targets: [Self.beta, Self.bitcoin])
        #expect(!vm.selectedIsRealMoney)
        vm.choose(Self.bitcoin)
        #expect(vm.selectedIsRealMoney)
        vm.choose(Self.beta)
        #expect(!vm.selectedIsRealMoney)
    }
}
