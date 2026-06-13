// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives the Import-wallet flow (restore from a 12/24-word recovery phrase). Platform-agnostic
/// and thin: word normalization lives in `WalletService.MnemonicInput` (parity-tested), word-list
/// and checksum validation are BDK's (`Mnemonic.fromString` → `.invalidMnemonic`), and this type
/// owns only the phase machine. Depends on an injected closure (AppState wires it to
/// `WalletManager.importWallet`).
///
/// Golden Rule §2: the entered phrase is never logged or echoed — a rejection surfaces only
/// `WalletError.invalidMnemonic.userMessage`. On success the phrase is cleared from UI state and
/// `AppState.hasWallets` re-roots the app, unmounting this flow.
@MainActor
@Observable
final class ImportViewModel {
    enum Phase: Equatable {
        case idle
        case importing
        case failed(String)   // user-safe message (already scrubbed by WalletError)
    }

    /// Raw user input (TextEditor binding). Normalized only at submit.
    var phrase = ""
    private(set) var phase: Phase = .idle

    private let importWallet: @MainActor (_ label: String, _ network: WalletNetwork, _ mnemonic: String) throws -> Void

    init(importWallet: @escaping @MainActor (_ label: String, _ network: WalletNetwork, _ mnemonic: String) throws -> Void) {
        self.importWallet = importWallet
    }

    var wordCount: Int { MnemonicInput.wordCount(phrase) }

    /// 12 or 24 words and not already importing. Checksum validity is only known at submit (BDK).
    var canSubmit: Bool {
        MnemonicInput.hasValidWordCount(phrase) && phase != .importing
    }

    var isImporting: Bool { phase == .importing }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Validate via BDK and persist (mnemonic → Keychain, record → store, selected). Synchronous
    /// key derivation — no network I/O; the first sync happens on Home after the app re-roots.
    func submit(label: String, network: WalletNetwork) {
        guard canSubmit else { return }
        phase = .importing
        do {
            try importWallet(label, network, MnemonicInput.normalize(phrase))
            // Success: drop the secret from UI state; AppState re-roots to Home.
            phrase = ""
            phase = .idle
        } catch let error as WalletError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't import the wallet. Please try again.")
        }
    }

    /// Clear a stale error as soon as the user edits the phrase again.
    func phraseEdited() {
        if case .failed = phase { phase = .idle }
    }
}
