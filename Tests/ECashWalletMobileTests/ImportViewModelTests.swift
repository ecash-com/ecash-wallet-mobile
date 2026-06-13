// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import WalletService
@testable import ECashWalletMobile

private let importValidPhrase = "abandon abandon abandon abandon abandon abandon "
    + "abandon abandon abandon abandon abandon about"

/// Import flow: word-count gating, that the phrase is NORMALIZED before it reaches the engine,
/// non-leaky error handling, and that a rejected phrase is kept on screen so the user can fix it.
/// The `importWallet` seam records what it received and can be programmed to throw.
@MainActor
@Suite struct ImportViewModelTests {

    private final class Recorder: @unchecked Sendable {
        var receivedMnemonic: String?
        var receivedLabel: String?
        var callCount = 0
        var errorToThrow: Error?
    }

    private func makeVM() -> (ImportViewModel, Recorder) {
        let rec = Recorder()
        let vm = ImportViewModel(importWallet: { label, _, mnemonic in
            rec.callCount += 1
            rec.receivedLabel = label
            rec.receivedMnemonic = mnemonic
            if let error = rec.errorToThrow { throw error }
        })
        return (vm, rec)
    }

    @Test func canSubmitOnlyForTwelveOrTwentyFourWords() {
        let (vm, _) = makeVM()
        #expect(!vm.canSubmit)                  // empty

        vm.phrase = "abandon abandon abandon"    // 3
        #expect(!vm.canSubmit)
        #expect(vm.wordCount == 3)

        vm.phrase = importValidPhrase            // 12
        #expect(vm.canSubmit)
        #expect(vm.wordCount == 12)

        // 11 words — one short.
        vm.phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        #expect(!vm.canSubmit)
    }

    @Test func submitNormalizesPhraseBeforeImport() {
        let (vm, rec) = makeVM()
        // Messy paste: mixed case, extra spaces, newlines, tabs.
        vm.phrase = "  Abandon   ABANDON\nabandon\tabandon abandon abandon "
            + "abandon abandon abandon abandon abandon ABOUT  "
        vm.submit(label: "Imported", network: .signet)

        #expect(rec.callCount == 1)
        // Engine receives a lowercased, single-spaced, trimmed phrase.
        #expect(rec.receivedMnemonic == importValidPhrase)
        #expect(rec.receivedLabel == "Imported")
        #expect(vm.phrase == "")        // secret cleared from UI state on success
        #expect(vm.phase == .idle)
    }

    @Test func invalidMnemonicShowsScrubbedErrorAndKeepsPhrase() {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.invalidMnemonic
        vm.phrase = importValidPhrase
        vm.submit(label: "W", network: .signet)

        #expect(vm.errorMessage == WalletError.invalidMnemonic.userMessage)
        #expect(vm.phrase == importValidPhrase)   // keep the input so the user can correct it
    }

    @Test func unknownErrorMapsToGenericMessage() {
        struct Boom: Error {}
        let (vm, rec) = makeVM()
        rec.errorToThrow = Boom()
        vm.phrase = importValidPhrase
        vm.submit(label: "W", network: .signet)
        #expect(vm.errorMessage == "Couldn't import the wallet. Please try again.")
    }

    @Test func editingClearsStaleError() {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.invalidMnemonic
        vm.phrase = importValidPhrase
        vm.submit(label: "W", network: .signet)
        #expect(vm.errorMessage != nil)

        vm.phraseEdited()
        #expect(vm.errorMessage == nil)   // editing dismisses the previous rejection
    }

    @Test func submitBlockedWhenWordCountInvalid() {
        let (vm, rec) = makeVM()
        vm.phrase = "abandon abandon"   // 2 words
        vm.submit(label: "W", network: .signet)
        #expect(rec.callCount == 0)   // never hit the engine with an obviously-wrong phrase
    }
}
