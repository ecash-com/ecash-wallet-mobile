// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The app's main tabs. Top-level so `AppState` can own the selection (lets "See all" on Home
/// switch to Activity).
enum MainTab: String, Hashable {
    case wallet, activity, dashboard, settings
}

/// The main shell once a wallet exists. Stock `TabView` → native tabs on each platform.
/// Tab icons resolve via `tabIcon(...)`: SF Symbols on iOS (the OS auto-fills the selected tab),
/// Material `.symbolset`s on Android (swapped to the filled variant on selection, Material 3 style).
struct MainTabView: View {
    @Environment(AppState.self) var app

    // Plain @State, NOT @AppStorage: persisting the selected tab meant a crash on one tab put
    // every subsequent launch straight back into that tab — a permanent crash loop (this also
    // masqueraded as "non-deterministic" crashes while debugging). Always boot to Wallet.
    @State var selection = MainTab.wallet   // not `private` — Fuse bridges @State (skip-fuse rule)

    /// Selection is plain state. There used to be a coercion here forcing the old News tab back to
    /// `.wallet` whenever CoinNews was unavailable, because that tab was conditionally REMOVED and a
    /// TabView must never point at a missing tag. Every tab is permanent now, so nothing needs it —
    /// and it once broke the tab on Bitcoin (the tap was rewritten straight back to `.wallet`).
    private var selectionBinding: Binding<MainTab> {
        Binding(get: { selection }, set: { selection = $0 })
    }

    /// Tab-bar icon. iOS tab bars force the `.fill` symbol variant on EVERY item, so we override it
    /// per-selection — `.none` for unselected (outline), `.fill` for selected. Android has no SF
    /// Symbols and doesn't auto-fill, so it swaps to the filled Material `.symbolset` on selection.
    @ViewBuilder
    private func tabBarIcon(_ base: Icon, _ fill: Icon, selected: Bool) -> some View {
        #if os(iOS)
        if let sf = base.sf {
            // iOS 15+ tab bars force the `.fill` variant on every item. `.environment(\.symbolVariants,
            // .none)` is the documented override (NOT `.symbolVariant(.none)`, which only appends and
            // leaves the inherited `.fill` in place). `.fill` for selected, `.none` (outline) otherwise.
            Image(systemName: sf).environment(\.symbolVariants, selected ? .fill : .none)
        } else {
            Image(icon: base)
        }
        #else
        Image(icon: selected ? fill : base).tabSized()
        #endif
    }

    var body: some View {
        TabView(selection: selectionBinding) {
            // No NavigationStack: Home presents only sheets/covers, and the switcher pill makes
            // a "Wallet" nav title redundant — the header IS the pill.
            WalletHomeScreen()
                .tabItem {
                    Label { Text("Wallet", bundle: .module, comment: "Wallet tab") }
                    icon: { tabBarIcon(Icon.wallet, Icon.walletFill, selected: selection == .wallet) }
                }
                .tag(MainTab.wallet)

            NavigationStack { ActivityScreen() }
                .tabItem {
                    Label { Text("Activity", bundle: .module, comment: "Activity tab") }
                    icon: { tabBarIcon(Icon.activity, Icon.activityFill, selected: selection == .activity) }
                }
                .tag(MainTab.activity)

            // Dashboard (replaced the News tab — docs/dashboard-plan.md): the eCash network, prices,
            // eCash.com news, and CoinNews as one of its sections. Always present, on every network.
            NavigationStack { DashboardScreen() }
                .tabItem {
                    Label { Text("Dashboard", bundle: .module, comment: "Dashboard tab") }
                    icon: { tabBarIcon(Icon.dashboard, Icon.dashboardFill, selected: selection == .dashboard) }
                }
                .tag(MainTab.dashboard)

            NavigationStack { SettingsScreen() }
                .tabItem {
                    Label { Text("Settings", bundle: .module, comment: "Settings tab") }
                    icon: { tabBarIcon(Icon.settings, Icon.settingsFill, selected: selection == .settings) }
                }
                .tag(MainTab.settings)
        }
        // Register for push once the main shell is reached (after onboarding). Fires the permission
        // prompt + fetches the device token; idempotent, so this no-ops on later launches.
        .task { await app.push.register() }
    }
}
