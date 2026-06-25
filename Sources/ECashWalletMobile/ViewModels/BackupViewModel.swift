// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives the Backup flow: intro gate → device auth → reveal (word chips) → verify (3 random
/// words, tap-choice) → done (marks `isBackedUp`, which clears the Home warning). Question
/// construction lives in `WalletService.BackupVerification` (parity-tested); this owns the steps.
///
/// Golden Rule §2: the mnemonic is held only while the flow is open and wiped on exit/finish;
/// it is never logged, and a wrong verify answer bounces back to reveal without echoing anything.
@MainActor
@Observable
final class BackupViewModel {
    enum Step: Equatable {
        case intro
        case authenticating
        case reveal
        case verify
        case done
        case failed(String)
    }

    private(set) var step: Step = .intro
    /// The revealed phrase as words, populated only after auth succeeds; wiped on exit.
    private(set) var words: [String] = []
    private(set) var questions: [BackupQuestion] = []
    private(set) var questionIndex = 0
    /// Set briefly when a verify answer was wrong (drives the "check again" notice on reveal).
    private(set) var verifyMissed = false

    /// The label of the wallet being backed up — recovery phrases are per-wallet (each wallet is its
    /// own seed), so the flow names which one. Captured at presentation time.
    let walletLabel: String

    private let loadMnemonic: @MainActor () throws -> String?
    private let markBackedUp: @MainActor () throws -> Void
    private let authenticate: (String) async -> Bool

    init(walletLabel: String = "",
         loadMnemonic: @escaping @MainActor () throws -> String?,
         markBackedUp: @escaping @MainActor () throws -> Void,
         authenticate: @escaping (String) async -> Bool) {
        self.walletLabel = walletLabel
        self.loadMnemonic = loadMnemonic
        self.markBackedUp = markBackedUp
        self.authenticate = authenticate
    }

    var currentQuestion: BackupQuestion? {
        questionIndex < questions.count ? questions[questionIndex] : nil
    }

    /// "I understand" tapped: device auth, then load + show the phrase.
    func begin() async {
        guard step == .intro else { return }
        step = .authenticating
        let ok = await authenticate("Unlock to reveal your recovery phrase")
        guard ok else {
            step = .intro // quietly back to the gate; user can retry
            return
        }
        do {
            guard let mnemonic = try loadMnemonic(), !mnemonic.isEmpty else {
                step = .failed("Couldn't load the recovery phrase for this wallet.")
                return
            }
            words = mnemonic.components(separatedBy: " ")
            step = .reveal
        } catch {
            step = .failed("Couldn't load the recovery phrase for this wallet.")
        }
    }

    /// "I've written them down" tapped: build a fresh quiz and start verifying.
    func startVerify() {
        guard step == .reveal, !words.isEmpty else { return }
        questions = BackupVerification.plan(words: words)
        questionIndex = 0
        verifyMissed = false
        step = .verify
    }

    /// A choice tapped on the current question. Right → next question or finish; wrong → back
    /// to the reveal so the user re-checks their copy (fresh questions on the next attempt).
    func answer(_ word: String) {
        guard step == .verify, let question = currentQuestion else { return }
        if word == question.answer {
            questionIndex += 1
            if questionIndex >= questions.count {
                finish()
            }
        } else {
            verifyMissed = true
            step = .reveal
        }
    }

    private func finish() {
        do {
            try markBackedUp()
            wipe()
            step = .done
        } catch {
            step = .failed("Couldn't save the backup state. Please try again.")
        }
    }

    /// Drop the secret from memory — called on finish and when the flow disappears.
    func wipe() {
        words = []
        questions = []
        questionIndex = 0
    }
}
