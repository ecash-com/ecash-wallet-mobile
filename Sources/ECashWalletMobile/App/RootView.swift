// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The app's logical root. Routes first launch (no wallets) to a focused create/import empty
/// state, otherwise the main tab shell. Sets the brand tint and appearance override ONCE,
/// globally. Rendered by `ECashWalletMobileRootView` (the platform bridge entry).
///
/// Native-first: only stock SwiftUI chrome here, so it renders as native SwiftUI on iOS and
/// native Compose/Material on Android. The brand appears only through `Theme` + the tint.
struct RootView: View {
    @AppStorage("appearance") var appearance = ""   // "" = system · "light" · "dark"
    @State var app = AppState()
    @State var privacyCovered = false   // not `private` — Fuse bridges @State (skip-fuse rule)
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        Group {
            if app.hasWallets && app.appLock.isLocked {
                // App-lock gate — only when there's a wallet to protect (never over onboarding).
                LockScreen()
            } else if app.hasWallets {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .environment(app)
        .brandNavigationTitleFont()
        .tint(Theme.Colors.accent)
        // Cap Dynamic Type so the largest accessibility sizes don't break the fixed-size amount/
        // address layouts. iOS only (real SwiftUI honors the upper-bound cap); Android font scaling
        // is a separate concern handled by Compose.
        #if os(iOS)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        #endif
        .preferredColorScheme(appearance == "dark" ? .dark
                              : appearance == "light" ? .light : nil)
        // Privacy cover: hides balances/addresses from the app-switcher snapshot whenever the app
        // isn't active (covers the app-lock grace window, where the lock screen isn't shown).
        // Rendered ONLY while covering — an always-present opacity-0 overlay with
        // `.allowsHitTesting(false)` still swallows every touch on Compose (Android), so the app
        // looks normal but nothing is tappable. Conditional insertion keeps the foreground fully
        // interactive; `.transition(.opacity)` + the `withAnimation` on `.active` gives the fade-out.
        .overlay {
            if privacyCovered {
                PrivacyCover()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        // App-lock grace window + privacy cover, both keyed off scenePhase:
        //  • leaving the foreground (`.inactive`/`.background`) → raise the cover INSTANTLY (no
        //    animation) so the OS snapshot is already obscured; `.background` also stamps the
        //    grace clock (we don't lock yet — a quick round-trip skips re-auth).
        //  • returning (`.active`) → re-lock iff we were away past the grace window, and FADE the
        //    cover out so the reveal isn't abrupt.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive:
                privacyCovered = true
            case .background:
                privacyCovered = true
                app.appLock.markBackgrounded()
            case .active:
                app.appLock.applyForegroundLock()
                withAnimation(.easeOut(duration: 0.28)) { privacyCovered = false }
            default:
                break
            }
        }
    }
}
