// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Puts a wallet's recovery phrase (or private key) back on this device, for a wallet whose public
/// data arrived without it — a move to a new phone, or a restored backup (`docs/key-storage.md §9`).
/// The wallet keeps its id, name, accounts and history; only the missing secret is written.
///
/// Thin: normalization and the check that the entered secret really is THIS wallet's live in
/// `WalletManager.restoreSecret`, which refuses anything that doesn't re-derive the wallet's stored
/// public descriptors. Golden Rule §2: the input is never logged or echoed — a rejection surfaces
/// only a scrubbed message — and it is cleared from UI state on success.
@MainActor
@Observable
final class RestoreKeyViewModel {
    enum Phase: Equatable {
        case idle
        case restoring
        case failed(String)
        case done
    }

    /// Raw input (TextEditor / TextField binding). Normalized by the manager at submit.
    var text = ""
    private(set) var phase: Phase = .idle

    let walletLabel: String
    /// A `.wif` wallet takes back its single private key; a `.mnemonic` wallet its phrase.
    let keyType: WalletKeyType
    var isPrivateKey: Bool { keyType == .wif }
    /// The address kind the phrase is checked against ("Native SegWit", "Taproot"…), shown so the
    /// user knows which wallet this is. Nil for a private-key wallet, which has no such choice.
    let addressTypeName: String?
    /// The wallet's current receive address — public data, shown so the user can recognize the
    /// wallet before typing a secret into it. Nil when it can't be derived (a Thunder-only wallet).
    let receiveAddress: String?

    private let restore: @MainActor (_ secret: String) throws -> Void

    init(walletLabel: String, keyType: WalletKeyType,
         addressTypeName: String? = nil, receiveAddress: String? = nil,
         restore: @escaping @MainActor (_ secret: String) throws -> Void) {
        self.walletLabel = walletLabel
        self.keyType = keyType
        self.addressTypeName = keyType == .wif ? nil : addressTypeName
        self.receiveAddress = receiveAddress
        self.restore = restore
    }

    var wordCount: Int { MnemonicInput.wordCount(text) }

    /// A phrase needs 12 or 24 words; a key just needs to be there. Whether it's the RIGHT one is
    /// decided at submit, by derivation.
    var canSubmit: Bool {
        if phase == .restoring || phase == .done { return false }
        if isPrivateKey { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return MnemonicInput.hasValidWordCount(text)
    }

    var isDone: Bool { phase == .done }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Clear a stale error as soon as the user edits again.
    func edited() {
        if case .failed = phase { phase = .idle }
    }

    func submit() {
        guard canSubmit else { return }
        phase = .restoring
        do {
            try restore(text)
            text = ""   // drop the secret from UI state
            phase = .done
        } catch let error as WalletError {
            phase = .failed(Self.message(for: error, isPrivateKey: isPrivateKey))
        } catch {
            phase = .failed("Couldn't restore this wallet. Please try again.")
        }
    }

    static func message(for error: WalletError, isPrivateKey: Bool) -> String {
        switch error {
        case .secretMismatch:
            return isPrivateKey
                ? "That private key belongs to a different wallet. Nothing was changed."
                : "That recovery phrase belongs to a different wallet. Nothing was changed."
        default:
            return error.userMessage
        }
    }
}
