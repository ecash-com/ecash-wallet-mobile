// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The app's main tabs. Top-level so `AppState` can own the selection (lets "See all" on Home
/// switch to Activity).
enum MainTab: String, Hashable {
    case wallet, activity, settings
}

/// The main shell once a wallet exists. Stock `TabView` → native tabs on each platform.
/// Tab icons are Material Symbols `.symbolset` resources (never SF Symbols) and render
/// identically on iOS and Android.
struct MainTabView: View {
    // Plain @State, NOT @AppStorage: persisting the selected tab meant a crash on one tab put
    // every subsequent launch straight back into that tab — a permanent crash loop (this also
    // masqueraded as "non-deterministic" crashes while debugging). Always boot to Wallet.
    @State var selection = MainTab.wallet   // not `private` — Fuse bridges @State (skip-fuse rule)

    var body: some View {
        TabView(selection: $selection) {
            // No NavigationStack: Home presents only sheets/covers, and the switcher pill makes
            // a "Wallet" nav title redundant — the header IS the pill.
            WalletHomeScreen()
                .tabItem {
                    Label { Text("Wallet", bundle: .module, comment: "Wallet tab") }
                    icon: { Image(icon: Icon.wallet).tabSized() }
                }
                .tag(MainTab.wallet)

            NavigationStack { ActivityScreen() }
                .tabItem {
                    Label { Text("Activity", bundle: .module, comment: "Activity tab") }
                    icon: { Image(icon: Icon.activity).tabSized() }
                }
                .tag(MainTab.activity)

            NavigationStack { SettingsScreen() }
                .tabItem {
                    Label { Text("Settings", bundle: .module, comment: "Settings tab") }
                    icon: { Image(icon: Icon.settings).tabSized() }
                }
                .tag(MainTab.settings)
        }
    }
}
