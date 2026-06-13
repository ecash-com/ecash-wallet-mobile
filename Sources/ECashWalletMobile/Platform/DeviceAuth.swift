// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService
#if os(iOS)
import LocalAuthentication
#endif

/// One cross-platform "prove it's you" gate for sensitive actions (Backup reveal; later
/// app-lock and per-send). iOS: LocalAuthentication (biometric, falls back to passcode).
/// Android: the framework BiometricPrompt via WalletService's platform glue. If the device has
/// nothing enrolled to check against, the gate passes — the flows behind it keep their explicit
/// confirmation steps, and a credential-less device has no credential to verify.
enum DeviceAuth {
    static func authenticate(reason: String) async -> Bool {
        #if os(iOS)
        let context = LAContext()
        var error: NSError?
        // Biometric OR device passcode — the right policy for a wallet gate.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true // nothing enrolled — pass through to the explicit gate
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: reason)
        } catch {
            return false // user cancelled or failed
        }
        #elseif os(Android)
        return await PlatformBridge.authenticateUser(reason: reason)
        #else
        return true // macOS host build (test/transpile target only)
        #endif
    }
}
