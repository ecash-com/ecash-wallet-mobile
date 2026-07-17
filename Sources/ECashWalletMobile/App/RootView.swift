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
    @State var wasBackgrounded = false  // true after a real background trip → drives foreground refresh
    @State var pushRouter = PushRouter.shared   // observe the shared push→UI router (Phase 2 alert)
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
        // In-app alert sheet for a tapped announcement push (Phase 2). Driven by the shared
        // PushRouter that NotificationDelegate.didReceive populates. Announcements carry no wallet
        // data, so presenting over any state (incl. the lock screen) is safe.
        .sheet(item: $pushRouter.pendingAlert) { alert in
            AlertSheet(alert: alert)
        }
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
                wasBackgrounded = true
                app.appLock.markBackgrounded()
            case .active:
                app.appLock.applyForegroundLock()
                withAnimation(.easeOut(duration: 0.28)) { privacyCovered = false }
                // Returning from a real background trip: re-pull the remote endpoints config so a
                // rotation takes effect without a cold launch. Guarded by `wasBackgrounded` so this
                // does NOT double-fetch right after launch (init already fetched); iOS goes
                // background → inactive → active, so we can't rely on the previous phase here.
                if wasBackgrounded {
                    wasBackgrounded = false
                    Task { await app.refreshRemoteEndpoints() }
                }
            default:
                break
            }
        }
    }
}
