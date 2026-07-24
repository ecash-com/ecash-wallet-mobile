// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives the Create-wallet flow's final step (generate → persist → select). Platform-agnostic and
/// testable: it depends only on an injected `create` closure (AppState wires it to `WalletManager`;
/// tests pass a stub), so the state machine is verified without touching BDK or the Keychain.
///
/// On success the closure flips `AppState.hasWallets`, which re-roots `RootView` to the main shell —
/// so there's no explicit "done" navigation here; the whole onboarding stack simply unmounts.
@MainActor
@Observable
final class CreateViewModel {
    enum Phase: Equatable {
        case idle
        case creating
        case failed(String)   // user-safe message (already scrubbed by WalletError)
    }

    /// The derivation script type for the new wallet (Advanced; default `.bip84` native segwit). A
    /// fresh seed has no coins to match, so this is a preference (e.g. create a Taproot wallet), not
    /// recovery. Ignored for Thunder (fixed ed25519 derivation).
    var scriptType: ScriptType = .bip84

    private let create: @MainActor (_ label: String, _ network: WalletNetwork, _ wordCount: Int, _ scriptType: ScriptType) throws -> Void
    private(set) var phase: Phase = .idle

    init(create: @escaping @MainActor (_ label: String, _ network: WalletNetwork, _ wordCount: Int, _ scriptType: ScriptType) throws -> Void) {
        self.create = create
    }

    var isCreating: Bool { phase == .creating }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Generate + persist a wallet on `network`. Synchronous BDK key derivation (no network I/O),
    /// so it's fast; surfaced as a brief `.creating` state. Errors map to a user-safe message.
    func submit(label: String, network: WalletNetwork, wordCount: Int = 12) {
        guard phase != .creating else { return }
        phase = .creating
        do {
            try create(label, network, wordCount, scriptType)
            // Success: AppState re-roots to Home; nothing else to do here.
        } catch let error as WalletError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't create the wallet. Please try again.")
        }
    }
}
