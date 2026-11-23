// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// The restore-in-place flow for a wallet whose secret isn't on this device (`docs/key-storage.md §9`).
/// Whether the secret is the RIGHT one is `WalletManager.restoreSecret`'s job (tested in
/// WalletService); here: the phase machine, the submit gate, and that nothing leaks or lingers.
@MainActor
@Suite struct RestoreKeyViewModelTests {

    private static let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    final class Calls: @unchecked Sendable { var secrets: [String] = [] }

    private func makeVM(keyType: WalletKeyType = .mnemonic, calls: Calls = Calls(),
                        failing: WalletError? = nil) -> RestoreKeyViewModel {
        RestoreKeyViewModel(walletLabel: "Savings", keyType: keyType) { secret in
            if let failing { throw failing }
            calls.secrets.append(secret)
        }
    }

    @Test func aPhraseNeedsTwelveOrTwentyFourWords() {
        let vm = makeVM()
        #expect(!vm.canSubmit)
        vm.text = "abandon abandon abandon"
        #expect(!vm.canSubmit)
        vm.text = Self.phrase
        #expect(vm.canSubmit)
    }

    @Test func aPrivateKeyWalletTakesAnyNonEmptyKey() {
        let vm = makeVM(keyType: .wif)
        #expect(vm.isPrivateKey)
        vm.text = "   "
        #expect(!vm.canSubmit)
        vm.text = "KwSomeKey"
        #expect(vm.canSubmit)
    }

    @Test func aSuccessfulRestoreClearsTheInput() {
        let calls = Calls()
        let vm = makeVM(calls: calls)
        vm.text = Self.phrase
        vm.submit()
        #expect(calls.secrets == [Self.phrase])
        #expect(vm.isDone)
        #expect(vm.text.isEmpty)        // the phrase doesn't stay in UI state
        #expect(!vm.canSubmit)          // and can't be sent twice
    }

    @Test func aPhraseForAnotherWalletIsReportedPlainly() {
        let vm = makeVM(failing: .secretMismatch)
        vm.text = Self.phrase
        vm.submit()
        #expect(!vm.isDone)
        #expect(vm.errorMessage == "That recovery phrase belongs to a different wallet. Nothing was changed.")
        // The message never repeats what was typed.
        #expect(vm.errorMessage?.contains("abandon") == false)
        #expect(vm.canSubmit)           // they can correct it and try again
    }

    @Test func aBadPhraseShowsTheScrubbedMessage() {
        let vm = makeVM(failing: .invalidMnemonic)
        vm.text = Self.phrase
        vm.submit()
        #expect(vm.errorMessage == WalletError.invalidMnemonic.userMessage)
    }

    @Test func aWrongPrivateKeySaysKeyNotPhrase() {
        let vm = makeVM(keyType: .wif, failing: .secretMismatch)
        vm.text = "KwSomeKey"
        vm.submit()
        #expect(vm.errorMessage == "That private key belongs to a different wallet. Nothing was changed.")
    }

    @Test func editingClearsAStaleError() {
        let vm = makeVM(failing: .secretMismatch)
        vm.text = Self.phrase
        vm.submit()
        #expect(vm.errorMessage != nil)
        vm.edited()
        #expect(vm.errorMessage == nil)
    }

    @Test func aPrivateKeyWalletShowsNoAddressType() {
        let wif = RestoreKeyViewModel(walletLabel: "Old", keyType: .wif, addressTypeName: "Legacy",
                                      receiveAddress: "1abc") { _ in }
        #expect(wif.addressTypeName == nil)
        #expect(wif.receiveAddress == "1abc")
        let seed = RestoreKeyViewModel(walletLabel: "Savings", keyType: .mnemonic, addressTypeName: "Taproot") { _ in }
        #expect(seed.addressTypeName == "Taproot")
        #expect(seed.receiveAddress == nil)
    }
}
