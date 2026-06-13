// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import WalletService
@testable import ECashWalletMobile

// File scope (nonisolated) so the `Seams` helper can use it as a property default.
private let backupSpecPhrase = "abandon abandon abandon abandon abandon abandon "
    + "abandon abandon abandon abandon abandon about"

/// The Backup flow state machine. The security-critical invariants: the phrase is NEVER revealed
/// without a successful device-auth, a wrong verify answer bounces back (can't be brute-stepped
/// past), and the secret is wiped from memory on finish. Driven through injected auth/load/mark
/// seams — no Keychain, no biometrics. Swift Testing so it runs on host + Android APK mode.
@MainActor
@Suite struct BackupViewModelTests {

    private final class Seams: @unchecked Sendable {
        var authResult = true
        var authCallCount = 0
        var mnemonic: String? = backupSpecPhrase
        var loadThrows = false
        var markCallCount = 0
        var markThrows = false
    }

    private func makeVM(_ seams: Seams = Seams()) -> (BackupViewModel, Seams) {
        let vm = BackupViewModel(
            loadMnemonic: {
                if seams.loadThrows { throw WalletError.persistenceFailed }
                return seams.mnemonic
            },
            markBackedUp: {
                seams.markCallCount += 1
                if seams.markThrows { throw WalletError.persistenceFailed }
            },
            authenticate: { _ in
                seams.authCallCount += 1
                return seams.authResult
            })
        return (vm, seams)
    }

    // MARK: - The gate

    @Test func successfulAuthRevealsPhraseSplitIntoWords() async {
        let (vm, seams) = makeVM()
        await vm.begin()
        #expect(seams.authCallCount == 1)
        #expect(vm.step == .reveal)
        #expect(vm.words.count == 12)
        #expect(vm.words.first == "abandon")
        #expect(vm.words.last == "about")
    }

    @Test func failedAuthNeverRevealsThePhrase() async {
        let seams = Seams()
        seams.authResult = false
        let (vm, _) = makeVM(seams)
        await vm.begin()
        #expect(vm.step == .intro)          // denied auth returns to the gate
        #expect(vm.words.isEmpty)           // the phrase must never load when auth fails
    }

    @Test func missingMnemonicFails() async {
        let seams = Seams()
        seams.mnemonic = nil
        let (vm, _) = makeVM(seams)
        await vm.begin()
        if case .failed = vm.step {} else { Issue.record("expected .failed, got \(vm.step)") }
        #expect(vm.words.isEmpty)
    }

    @Test func emptyMnemonicFails() async {
        let seams = Seams()
        seams.mnemonic = ""
        let (vm, _) = makeVM(seams)
        await vm.begin()
        if case .failed = vm.step {} else { Issue.record("expected .failed, got \(vm.step)") }
    }

    @Test func beginIsNoOpOutsideIntro() async {
        let (vm, seams) = makeVM()
        await vm.begin()                 // intro → reveal
        #expect(vm.step == .reveal)
        await vm.begin()                 // from reveal: must not re-auth
        #expect(seams.authCallCount == 1)
        #expect(vm.step == .reveal)
    }

    // MARK: - Verify

    @Test func startVerifyBuildsQuiz() async {
        let (vm, _) = makeVM()
        await vm.begin()
        vm.startVerify()
        #expect(vm.step == .verify)
        #expect(vm.questions.count == 3)
        #expect(vm.currentQuestion != nil)
    }

    @Test func correctAnswersWalkToDoneAndWipeSecret() async {
        let (vm, seams) = makeVM()
        await vm.begin()
        vm.startVerify()
        // Answer each generated question correctly by reading its own answer.
        for _ in 0..<vm.questions.count {
            guard let q = vm.currentQuestion else { break }
            vm.answer(q.answer)
        }
        #expect(vm.step == .done)
        #expect(seams.markCallCount == 1)   // wallet marked backed up exactly once
        #expect(vm.words.isEmpty)           // secret wiped from memory on finish
        #expect(vm.questions.isEmpty)
    }

    @Test func wrongAnswerBouncesBackToRevealWithoutFinishing() async {
        let (vm, seams) = makeVM()
        await vm.begin()
        vm.startVerify()
        guard let q = vm.currentQuestion else { Issue.record("no question"); return }
        // Pick any word that is NOT the correct answer.
        let wrong = vm.words.first { $0 != q.answer } ?? "zzz"
        vm.answer(wrong)
        #expect(vm.step == .reveal)         // a wrong answer returns to the words
        #expect(vm.verifyMissed)
        #expect(seams.markCallCount == 0)   // must NOT mark backed up on a miss
    }

    @Test func wrongThenCorrectStillSucceeds() async {
        let (vm, seams) = makeVM()
        await vm.begin()
        vm.startVerify()
        if let q = vm.currentQuestion {
            vm.answer(vm.words.first { $0 != q.answer } ?? "zzz")   // miss → reveal
        }
        #expect(vm.step == .reveal)
        vm.startVerify()   // fresh quiz
        for _ in 0..<vm.questions.count {
            guard let q = vm.currentQuestion else { break }
            vm.answer(q.answer)
        }
        #expect(vm.step == .done)
        #expect(seams.markCallCount == 1)
    }

    @Test func markBackedUpFailureSurfacesError() async {
        let seams = Seams()
        seams.markThrows = true
        let (vm, _) = makeVM(seams)
        await vm.begin()
        vm.startVerify()
        for _ in 0..<vm.questions.count {
            guard let q = vm.currentQuestion else { break }
            vm.answer(q.answer)
        }
        if case .failed = vm.step {} else { Issue.record("expected .failed when persistence throws") }
    }

    @Test func answerIsNoOpOutsideVerify() async {
        let (vm, seams) = makeVM()
        await vm.begin()   // at reveal, not verify
        vm.answer("abandon")
        #expect(vm.step == .reveal)
        #expect(seams.markCallCount == 0)
    }
}
