// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Brand the navigation-bar TITLE with our heading font, the platform-native way (never a custom
// principal toolbar item — that would lose the large-title behavior on iOS). We keep each
// platform's NATIVE title sizing/behavior and only swap the typeface, per the native-first rule
// (stock chrome, brand via fonts/tint/colors).
//
//  • iOS     — `UINavigationBarAppearance`, set once globally (this modifier). Affects every
//              `NavigationStack` in the app.
//  • Android — handled NATIVELY in `Android/app/src/main/kotlin/Main.kt`, which wraps the Skip root
//              in a Compose `MaterialTheme` whose `Typography` re-fonts the title roles. It CANNOT
//              be done from here: in a Fuse app a SwiftUI view body's `#if SKIP` branch never runs
//              on Android (the body bridges back to native Swift), so `material3TopAppBar` /
//              ComposeView in an app-module ViewModifier is dead code. Compose theming must live in
//              the editable Kotlin root.

extension View {
    /// Apply the brand nav-title font app-wide. Call once at the app root. (No-op on Android, where
    /// the font is applied via `Main.kt`'s Compose typography.)
    func brandNavigationTitleFont() -> some View {
        modifier(BrandNavigationTitleFont())
    }
}

struct BrandNavigationTitleFont: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { BrandNavigationTitleFont.applyIOSAppearance() }
    }

    /// Restyle the global `UINavigationBar` appearance to use our heading font for both the inline
    /// and large title, at the platform's native point sizes. Idempotent — safe to call on every
    /// `onAppear`. We touch only the font (not background/color) so the bar stays native: default
    /// label color, default translucent background, native large-title collapse. No-op where UIKit
    /// is unavailable (the Android / transpile build).
    static func applyIOSAppearance() {
        #if canImport(UIKit)
        let inlineFont = UIFont(name: "SpaceGrotesk-SemiBold", size: 17)
        let largeFont = UIFont(name: "SpaceGrotesk-Bold", size: 34)

        func restyle(_ appearance: UINavigationBarAppearance) {
            if let inlineFont { appearance.titleTextAttributes[.font] = inlineFont }
            if let largeFont { appearance.largeTitleTextAttributes[.font] = largeFont }
        }

        // Standard/compact keep the native opaque-on-scroll background; scroll-edge stays
        // transparent (the iOS default for large titles at the top of a scroll view).
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        restyle(standard)

        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        restyle(scrollEdge)

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = standard
        proxy.compactAppearance = standard
        proxy.scrollEdgeAppearance = scrollEdge
        #endif
    }
}
