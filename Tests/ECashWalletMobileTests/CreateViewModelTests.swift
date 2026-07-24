// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import WalletService
@testable import ECashWalletMobile

/// Create flow: passes the label/network through, maps errors to user-safe messages, and guards
/// against a double-submit (the create closure does real key derivation + persistence — running
/// it twice would strand a wallet). On success the phase stays `.creating` because AppState
/// re-roots Home and the view unmounts; there is intentionally no "done" state here.
@MainActor
@Suite struct CreateViewModelTests {

    private final class Recorder: @unchecked Sendable {
        var callCount = 0
        var label: String?
        var network: WalletNetwork?
        var wordCount: Int?
        var scriptType: ScriptType?
        var errorToThrow: Error?
    }

    private func makeVM() -> (CreateViewModel, Recorder) {
        let rec = Recorder()
        let vm = CreateViewModel(create: { label, network, wordCount, scriptType in
            rec.callCount += 1
            rec.label = label
            rec.network = network
            rec.wordCount = wordCount
            rec.scriptType = scriptType
            if let error = rec.errorToThrow { throw error }
        })
        return (vm, rec)
    }

    @Test func submitPassesLabelAndNetwork() {
        let (vm, rec) = makeVM()
        vm.submit(label: "Wallet 1", network: .signet)
        #expect(rec.callCount == 1)
        #expect(rec.label == "Wallet 1")
        #expect(rec.network == .signet)
        #expect(rec.wordCount == 12)   // default seed length
        #expect(vm.errorMessage == nil)
    }

    @Test func submitPassesChosenWordCount() {
        let (vm, rec) = makeVM()
        vm.submit(label: "W", network: .signet, wordCount: 24)
        #expect(rec.wordCount == 24)
    }

    @Test func defaultsToNativeSegwit() {
        let (vm, rec) = makeVM()
        vm.submit(label: "W", network: .ecash)
        #expect(rec.scriptType == .bip84)          // default = native segwit
    }

    @Test func passesChosenScriptType() {
        let (vm, rec) = makeVM()
        vm.scriptType = .bip86                      // user picks Taproot in Advanced
        vm.submit(label: "W", network: .ecash)
        #expect(rec.scriptType == .bip86)
    }

    @Test func walletErrorMapsToUserMessage() {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.persistenceFailed
        vm.submit(label: "W", network: .signet)
        #expect(vm.errorMessage == WalletError.persistenceFailed.userMessage)
    }

    @Test func unknownErrorMapsToGenericMessage() {
        struct Boom: Error {}
        let (vm, rec) = makeVM()
        rec.errorToThrow = Boom()
        vm.submit(label: "W", network: .signet)
        #expect(vm.errorMessage == "Couldn't create the wallet. Please try again.")
    }

    @Test func doubleSubmitIsGuardedAfterSuccess() {
        let (vm, rec) = makeVM()
        vm.submit(label: "W", network: .signet)   // → .creating (success leaves it there)
        #expect(vm.isCreating)
        vm.submit(label: "W", network: .signet)   // blocked by the `phase != .creating` guard
        #expect(rec.callCount == 1)   // must not create a second wallet while one is in flight
    }

    @Test func canRetryAfterFailure() {
        let (vm, rec) = makeVM()
        rec.errorToThrow = WalletError.persistenceFailed
        vm.submit(label: "W", network: .signet)    // → .failed
        #expect(vm.errorMessage != nil)

        rec.errorToThrow = nil
        vm.submit(label: "W", network: .signet)    // failed is not creating → allowed
        #expect(rec.callCount == 2)   // a failed attempt can be retried
    }
}
