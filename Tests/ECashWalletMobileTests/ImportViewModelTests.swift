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
        var receivedWIF: String?
        var receivedLabel: String?
        var callCount = 0
        var wifCallCount = 0
        var errorToThrow: Error?
        var wifErrorToThrow: Error?
        var previewResult: String?   // what the injected previewWIF returns
        var receivedScriptType: ScriptType?   // what importWallet received
        var seedPreviewResult: String?        // what the injected previewSeed returns
    }

    private func makeVM() -> (ImportViewModel, Recorder) {
        let rec = Recorder()
        let vm = ImportViewModel(
            importWallet: { label, _, mnemonic, scriptType in
                rec.callCount += 1
                rec.receivedLabel = label
                rec.receivedMnemonic = mnemonic
                rec.receivedScriptType = scriptType
                if let error = rec.errorToThrow { throw error }
            },
            importPrivateKey: { label, _, wif in
                rec.wifCallCount += 1
                rec.receivedLabel = label
                rec.receivedWIF = wif
                if let error = rec.wifErrorToThrow { throw error }
            },
            previewWIF: { _, _ in rec.previewResult },
            previewSeed: { _, _, _ in rec.seedPreviewResult })
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

    @Test func submitPassesSelectedScriptType() {
        let (vm, rec) = makeVM()
        vm.phrase = importValidPhrase
        vm.scriptType = .bip44          // user picks Legacy in Advanced
        vm.submit(label: "Imported", network: .ecash)
        #expect(rec.callCount == 1)
        #expect(rec.receivedScriptType == .bip44)   // the choice reaches the engine seam
    }

    @Test func defaultScriptTypeIsBip84() {
        let (vm, rec) = makeVM()
        vm.phrase = importValidPhrase
        vm.submit(label: "W", network: .ecash)
        #expect(rec.receivedScriptType == .bip84)   // unchanged common case
    }

    @Test func seedPreviewOnlyDerivesForValidWordCount() {
        let (vm, rec) = makeVM()
        rec.seedPreviewResult = "bc1qpreview"
        vm.phrase = "abandon abandon abandon"       // 3 words — not a full mnemonic
        vm.updateSeedPreview(network: .ecash)
        #expect(vm.seedPreviewAddress == nil)       // no derivation attempted
        vm.phrase = importValidPhrase               // 12 words
        vm.updateSeedPreview(network: .ecash)
        #expect(vm.seedPreviewAddress == "bc1qpreview")
    }

    @Test func seedPreviewNotDerivedForThunder() {
        let (vm, rec) = makeVM()
        rec.seedPreviewResult = "bc1qwouldbewrong"   // BDK preview path would return a Bitcoin address
        vm.phrase = importValidPhrase
        vm.updateSeedPreview(network: .thunder)
        #expect(vm.seedPreviewAddress == nil)         // Thunder = ed25519 fixed derivation, no preview
    }

    @Test func seedPreviewNotShownForPrivateKeyKind() {
        let (vm, rec) = makeVM()
        rec.seedPreviewResult = "bc1qpreview"
        vm.kind = .privateKey
        vm.phrase = importValidPhrase
        vm.updateSeedPreview(network: .ecash)
        #expect(vm.seedPreviewAddress == nil)       // seed preview is a recovery-phrase-only guardrail
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

    // MARK: - Private key (WIF) mode

    @Test func privateKeyModeGatesOnDerivablePreview() {
        let (vm, rec) = makeVM()
        vm.kind = .privateKey
        vm.wif = "Kzjzb4…"

        rec.previewResult = nil          // key doesn't derive
        vm.updatePreview(network: .ecash)
        #expect(vm.previewAddress == nil)
        #expect(!vm.canSubmit)           // can't import a key that doesn't derive

        rec.previewResult = "14kwDb3YYj6cdhz9fxGftn1Uga5vdtfrxP"
        vm.updatePreview(network: .ecash)
        #expect(vm.previewAddress == "14kwDb3YYj6cdhz9fxGftn1Uga5vdtfrxP")
        #expect(vm.canSubmit)
    }

    @Test func submitInPrivateKeyModeCallsImportPrivateKeyWithTrimmedWIF() {
        let (vm, rec) = makeVM()
        vm.kind = .privateKey
        vm.wif = "  Kzjzb4aapsgaqrrVuDe6DongJbMxrq7pyLTwRWoeGJU5hHKUekWj  "
        rec.previewResult = "14kwDb3YYj6cdhz9fxGftn1Uga5vdtfrxP"
        vm.updatePreview(network: .ecash)

        vm.submit(label: "Claimed", network: .ecash)

        #expect(rec.wifCallCount == 1)
        #expect(rec.callCount == 0)        // did NOT go through the mnemonic path
        #expect(rec.receivedWIF == "Kzjzb4aapsgaqrrVuDe6DongJbMxrq7pyLTwRWoeGJU5hHKUekWj")  // trimmed
        #expect(rec.receivedLabel == "Claimed")
        #expect(vm.wif == "")              // secret cleared from UI on success
        #expect(vm.previewAddress == nil)
        #expect(vm.phase == .idle)
    }

    @Test func privateKeyErrorSurfacesScrubbedMessageAndKeepsInput() {
        let (vm, rec) = makeVM()
        vm.kind = .privateKey
        vm.wif = "Kzjzb4…"
        rec.previewResult = "14kwDb3…"
        vm.updatePreview(network: .ecash)
        rec.wifErrorToThrow = WalletError.invalidPrivateKey

        vm.submit(label: "W", network: .ecash)

        #expect(vm.errorMessage == WalletError.invalidPrivateKey.userMessage)
        #expect(vm.wif == "Kzjzb4…")       // keep the input so the user can fix it
    }

    @Test func emptyWIFClearsPreview() {
        let (vm, rec) = makeVM()
        vm.kind = .privateKey
        rec.previewResult = "14kwDb3…"
        vm.wif = "Kzjzb4…"
        vm.updatePreview(network: .ecash)
        #expect(vm.previewAddress != nil)

        vm.wif = "   "                     // whitespace only
        vm.updatePreview(network: .ecash)
        #expect(vm.previewAddress == nil)  // never calls preview on empty
    }
}
