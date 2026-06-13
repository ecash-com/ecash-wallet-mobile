// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// App-lock state: requires device authentication (biometric/passcode) to enter the app on a
/// cold launch and after returning from the background (CLAUDE.md §7). Toggleable in Settings.
///
/// Pure + testable: device auth and persistence are injected seams, so the lock state machine is
/// unit-tested without LocalAuthentication / BiometricPrompt / UserDefaults. `AppState` wires the
/// real `DeviceAuth` + `UserDefaults`.
///
/// Pass-through note: `DeviceAuth` returns true when the device has no biometric/passcode enrolled
/// (nothing to check against). So enabling app-lock on a credential-less device/emulator is a
/// no-op gate — correct, since such a device can't be protected by one.
@MainActor
@Observable
final class AppLockModel {
    /// Whether the gate is armed (persisted). Default ON for a wallet.
    private(set) var enabled: Bool
    /// Whether the app is currently locked (auth required to proceed).
    private(set) var isLocked: Bool
    /// True while an auth prompt is in flight (drives the Unlock button's spinner; re-entrancy guard).
    private(set) var authenticating = false

    private let authenticate: (String) async -> Bool
    private let persist: (Bool) -> Void

    init(enabled: Bool,
         startLocked: Bool,
         authenticate: @escaping (String) async -> Bool,
         persist: @escaping (Bool) -> Void) {
        self.enabled = enabled
        self.isLocked = startLocked
        self.authenticate = authenticate
        self.persist = persist
    }

    /// Toggle the setting (from Settings). Turning it ON takes effect on the next background/launch
    /// — it never locks you out mid-session. Turning it OFF clears any active lock immediately.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        persist(on)
        if !on { isLocked = false }
    }

    /// Engage the lock when the app leaves the foreground (call from scenePhase → background).
    func lockOnBackground() {
        if enabled { isLocked = true }
    }

    /// Attempt to clear the lock via device auth. No-op if already unlocked or mid-prompt
    /// (so the auto-attempt on appear and a manual Unlock tap can't double-prompt).
    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        let ok = await authenticate("Unlock eCash.com Wallet")
        if ok { isLocked = false }
        authenticating = false
    }
}
