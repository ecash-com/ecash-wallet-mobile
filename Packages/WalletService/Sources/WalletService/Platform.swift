// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Small platform-glue that needs DIRECT Android/Kotlin interop. It lives here, in the transpiled
/// (Lite) module, on purpose: `#if SKIP` Kotlin interop works cleanly here (same mechanism that
/// runs bdk-android), whereas calling these Android APIs from the Fuse app's NATIVE Swift via
/// `AnyDynamicObject` hits ambiguous-dispatch dead-ends. Bridged to the app like the rest of the
/// public surface; the signature is bridge-safe (String in, nothing out).
public enum PlatformBridge {
    /// Copy text to the Android system clipboard. No-op off Android — the app uses `UIPasteboard`
    /// directly on iOS and only routes here on Android.
    public static func copyToClipboard(_ text: String) {
        #if SKIP
        let context = ProcessInfo.processInfo.androidContext
        // Safe cast: if the service ever isn't a ClipboardManager, copying silently no-ops
        // rather than crashing (no force-unwraps/casts on platform-derived values).
        guard let clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager else {
            return
        }
        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("address", text))
        #endif
    }

    /// Block (or unblock) screen capture for the whole window — Android `FLAG_SECURE`.
    /// Used by seed-bearing screens (Backup reveal/verify, Import). No-op off Android and when
    /// no activity is tracked (fail-safe: the screen still shows; capture just isn't blocked).
    /// iOS has no capture-prevention API; the app obscures on backgrounding instead (§7).
    public static func setSecureScreen(_ secure: Bool) {
        #if SKIP
        guard let activity = AndroidActivityHolder.current else { return }
        activity.runOnUiThread {
            if secure {
                activity.window.setFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE,
                                         android.view.WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
        #endif
    }

    /// Authenticate the user with the device's biometric/credential prompt
    /// (`android.hardware.biometrics.BiometricPrompt`, framework — API 28+, no extra dependency).
    /// Returns true on success, false on cancel/failure. If no biometric/credential is available
    /// (common on emulators), returns true — the flow's explicit "I understand" gate still stands,
    /// and a device with no credential can't be protected by one. iOS authenticates app-side
    /// via LocalAuthentication; this is only the Android path.
    public static func authenticateUser(reason: String) async -> Bool {
        #if SKIP
        guard let activity = AndroidActivityHolder.current else { return true }
        return await withCheckedContinuation { continuation in
            let executor = activity.mainExecutor   // framework API 28+, no androidx dependency
            let builder = android.hardware.biometrics.BiometricPrompt.Builder(activity)
                .setTitle("Unlock")
                .setSubtitle(reason)

            if android.os.Build.VERSION.SDK_INT >= 30 {
                builder.setAllowedAuthenticators(
                    android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_WEAK
                    | android.hardware.biometrics.BiometricManager.Authenticators.DEVICE_CREDENTIAL)
            } else if android.os.Build.VERSION.SDK_INT >= 29 {
                builder.setDeviceCredentialAllowed(true)
            } else {
                builder.setNegativeButton("Cancel", executor,
                    android.content.DialogInterface.OnClickListener { _, _ in })
            }

            let callback = BiometricCallback(onResult: { ok in continuation.resume(returning: ok) })
            builder.build().authenticate(android.os.CancellationSignal(), executor, callback)
        }
        #else
        return true
        #endif
    }
}

#if SKIP
/// Receives the BiometricPrompt outcome. Errors meaning "no biometrics/credential to check"
/// resolve true (nothing to authenticate against); explicit cancel/lockout resolves false.
/// One-shot: the prompt calls exactly one terminal callback.
// SKIP @nobridge
public final class BiometricCallback: android.hardware.biometrics.BiometricPrompt.AuthenticationCallback {
    private let onResult: (Bool) -> Void

    public init(onResult: @escaping (Bool) -> Void) {
        self.onResult = onResult
        super.init()
    }

    public override func onAuthenticationSucceeded(result: android.hardware.biometrics.BiometricPrompt.AuthenticationResult?) {
        onResult(true)
    }

    public override func onAuthenticationError(errorCode: Int, errString: CharSequence?) {
        // 11 = NO_BIOMETRICS, 12 = HW_NOT_PRESENT, 1 = HW_UNAVAILABLE, 14 = NO_DEVICE_CREDENTIAL:
        // nothing enrolled to check against — let the flow proceed (the explicit gate remains).
        // Everything else (user cancel 10/13, lockout 7/9, …) denies.
        let unavailable = errorCode == 11 || errorCode == 12 || errorCode == 1 || errorCode == 14
        onResult(unavailable)
    }
    // onAuthenticationFailed = a bad attempt; the prompt stays up for retry — not terminal.
}

/// The current foreground Activity, set by the app's `Main.kt` lifecycle glue (the transpiled
/// module can't reach `skip.ui.UIApplication`; the app CAN reach this class). Android-only.
// SKIP @nobridge
public final class AndroidActivityHolder {
    public static var current: android.app.Activity? = nil
    public init() {}
}
#endif

#endif // !SKIP_BRIDGE
