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

    /// What the user is importing — chosen under the "Advanced" section, defaults to a recovery
    /// phrase. `.privateKey` is a single legacy WIF → a one-address wallet (`docs/wif-import-and-sweep.md`).
    enum Kind: Equatable {
        case recoveryPhrase
        case privateKey
    }

    /// Raw phrase input (TextEditor binding). Normalized only at submit.
    var phrase = ""
    /// Raw WIF input (private-key mode).
    var wif = ""
    var kind: Kind = .recoveryPhrase
    /// The derivation script type for a recovery-phrase import (Advanced). Defaults to `.bip84` so the
    /// common case is unchanged; a user restoring from another wallet picks the type their coins live
    /// at (`docs/custom-derivation-path-import.md`). Ignored for `.privateKey`.
    var scriptType: ScriptType = .bip84
    /// The `1…` address the entered WIF derives to, live (nil = empty or not-yet-valid). Doubles as
    /// the submit gate for `.privateKey`: a key that doesn't derive can't be imported. Never the WIF.
    private(set) var previewAddress: String?
    /// The first receive address the entered PHRASE derives at the selected script type, live — the
    /// Advanced guardrail so the user can confirm it matches their old wallet before importing. Nil
    /// until the phrase is a full valid mnemonic. Informational only (doesn't gate submit).
    private(set) var seedPreviewAddress: String?
    private(set) var phase: Phase = .idle

    private let importWallet: @MainActor (_ label: String, _ network: WalletNetwork, _ mnemonic: String, _ scriptType: ScriptType) throws -> Void
    private let importPrivateKey: @MainActor (_ label: String, _ network: WalletNetwork, _ wif: String) throws -> Void
    private let previewWIF: @MainActor (_ wif: String, _ network: WalletNetwork) -> String?
    private let previewSeed: @MainActor (_ mnemonic: String, _ scriptType: ScriptType, _ network: WalletNetwork) -> String?

    init(importWallet: @escaping @MainActor (_ label: String, _ network: WalletNetwork, _ mnemonic: String, _ scriptType: ScriptType) throws -> Void,
         importPrivateKey: @escaping @MainActor (_ label: String, _ network: WalletNetwork, _ wif: String) throws -> Void,
         previewWIF: @escaping @MainActor (_ wif: String, _ network: WalletNetwork) -> String?,
         previewSeed: @escaping @MainActor (_ mnemonic: String, _ scriptType: ScriptType, _ network: WalletNetwork) -> String?) {
        self.importWallet = importWallet
        self.importPrivateKey = importPrivateKey
        self.previewWIF = previewWIF
        self.previewSeed = previewSeed
    }

    var wordCount: Int { MnemonicInput.wordCount(phrase) }

    /// Ready to import: for a phrase, 12/24 words; for a WIF, it must derive (previewAddress set).
    /// Checksum/key validity is BDK's; not importing.
    var canSubmit: Bool {
        if phase == .importing { return false }
        switch kind {
        case .recoveryPhrase: return MnemonicInput.hasValidWordCount(phrase)
        case .privateKey: return previewAddress != nil
        }
    }

    var isImporting: Bool { phase == .importing }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Recompute the live WIF → address preview (call on WIF or network change, and when switching
    /// import kind). Also clears a stale error. Synchronous BDK derivation — no network I/O.
    func updatePreview(network: WalletNetwork) {
        let trimmed = wif.trimmingCharacters(in: .whitespacesAndNewlines)
        previewAddress = trimmed.isEmpty ? nil : previewWIF(trimmed, network)
        if case .failed = phase { phase = .idle }
    }

    /// Recompute the live phrase → first-address preview at the selected script type (call on phrase,
    /// script-type, or network change). Only derives once the phrase is a full valid mnemonic; a bad
    /// checksum yields nil (the preview closure returns nil on throw). Synchronous — no network I/O.
    func updateSeedPreview(network: WalletNetwork) {
        // Thunder is ed25519 with a fixed derivation — no script-type preview (the BDK preview path
        // would derive a misleading Bitcoin address). Only BDK/secp256k1 networks get a seed preview.
        guard kind == .recoveryPhrase, network != .thunder, MnemonicInput.hasValidWordCount(phrase) else {
            seedPreviewAddress = nil
            return
        }
        seedPreviewAddress = previewSeed(MnemonicInput.normalize(phrase), scriptType, network)
    }

    /// Validate via BDK and persist (secret → Keychain, record → store, selected). Branches on
    /// `kind`. Synchronous key work — no network I/O; the first sync happens on Home after re-root.
    func submit(label: String, network: WalletNetwork) {
        guard canSubmit else { return }
        phase = .importing
        do {
            switch kind {
            case .recoveryPhrase:
                try importWallet(label, network, MnemonicInput.normalize(phrase), scriptType)
            case .privateKey:
                try importPrivateKey(label, network, wif.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Success: drop the secret(s) from UI state; AppState re-roots to Home.
            phrase = ""
            wif = ""
            previewAddress = nil
            seedPreviewAddress = nil
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
