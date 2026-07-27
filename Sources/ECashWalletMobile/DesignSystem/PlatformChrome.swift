// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Small helpers that apply iOS-only chrome modifiers and no-op elsewhere, so call sites stay
/// clean and we honor native-first: iOS gets the Apple idiom, Android falls back to its own
/// native default (which Skip renders via Compose/Material). Keeps `#if` out of the screens.
extension View {
    /// Inset-grouped list styling on iOS; native default on Android/macOS.
    @ViewBuilder
    func groupedListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self
        #endif
    }

    /// Force a grouped `List` onto the app's base background (`bg0`) instead of the system grouped
    /// color. Inside a sheet the system palette shifts one level lighter ("grey list in a sheet"),
    /// so a grouped list in a sheet won't match the same list at a tab root (Settings). iOS-only;
    /// Android/Compose renders its own surface. Pair with `.listRowBackground(Theme.Colors.bg2)`.
    @ViewBuilder
    func themedGroupedListBackground() -> some View {
        #if os(iOS)
        self.scrollContentBackground(.hidden).background(Theme.Colors.bg0)
        #else
        self
        #endif
    }

    /// Force a FLAT (plain-style) list onto the app base background (`bg0`) on BOTH platforms, so the
    /// surface is uniformly bg0 with no system grouping tint (iOS) and no Material `surfaceVariant`
    /// grey (Android). Pair with `.listStyle(.plain)` + `.listRowBackground(Theme.Colors.bg0)` for a
    /// flat list (no card "bubbles"). `#if os(Android)` is honored in Fuse view bodies (only `#if SKIP`
    /// is dead there); macOS host has no `scrollContentBackground` quirk to worry about.
    @ViewBuilder
    func themedFlatListBackground() -> some View {
        #if os(iOS)
        self.scrollContentBackground(.hidden).background(Theme.Colors.bg0)
        #elseif os(Android)
        self.background(Theme.Colors.bg0)
        #else
        self
        #endif
    }

    /// Make a whole list row tappable, including the empty space a `Spacer` occupies.
    ///
    /// iOS-only: `contentShape` isn't part of SkipUI's surface, and Android doesn't need it — a
    /// Compose row is hit-testable across its full width already. Without it on iOS, taps that land
    /// in the gap between a row's label and its trailing edge do nothing, which reads as a dead row.
    @ViewBuilder
    func fullRowTapTarget() -> some View {
        #if os(iOS)
        self.contentShape(Rectangle())
        #else
        self
        #endif
    }

    /// Hide a list row's TOP separator (the hairline a plain `List` draws above its first row, which
    /// reads as a divider right under the nav bar). iOS-only — `listRowSeparator` is on the SkipUI
    /// Compose-crash watchlist for Android, and the macOS host lacks the `edges:` overload; Android
    /// rows fit without it.
    @ViewBuilder
    func hideTopRowSeparator() -> some View {
        #if os(iOS)
        self.listRowSeparator(.hidden, edges: .top)
        #else
        self
        #endif
    }

    /// Hide the bottom tab bar for this view (a pushed full-height detail, e.g. a story page).
    /// Gated off the macOS host build, where `ToolbarPlacement.tabBar` is marked unavailable (macOS
    /// is only the transpile/test target — §3); iOS + Android (Compose) both honor it.
    @ViewBuilder
    func hideTabBar() -> some View {
        #if os(macOS)
        self
        #else
        self.toolbar(.hidden, for: .tabBar)
        #endif
    }

    /// Inline (centered, non-large) navigation title on iOS — the right style for sheets, and it
    /// reliably picks up the brand inline-title appearance. No-op on Android (its sheet top app bar
    /// is already inline) and on the macOS host (where `navigationBarTitleDisplayMode` doesn't exist).
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Large control size on iOS; native default sizing on Android/macOS.
    @ViewBuilder
    func largeControlSize() -> some View {
        #if os(iOS)
        self.controlSize(.large)
        #else
        self
        #endif
    }

    /// `fullScreenCover` on iOS/Android; plain `sheet` on the macOS host build, where
    /// `fullScreenCover` doesn't exist (macOS is only the transpile/test target — §3).
    @ViewBuilder
    func fullScreenFlow<Content: View>(isPresented: Binding<Bool>,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        self.sheet(isPresented: isPresented, content: content)
        #else
        self.fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }

    /// Disable auto-capitalization on iOS (addresses/URIs are case-sensitive); Android's
    /// Compose text field doesn't capitalize plain fields, and macOS lacks the API.
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Hide a TextEditor's built-in scroll background on iOS so a Theme background can show
    /// through; Android/macOS render their native default (restyled in the polish round).
    @ViewBuilder
    func plainEditorBackground() -> some View {
        #if os(iOS)
        self.scrollContentBackground(.hidden)
        #else
        self
        #endif
    }

    /// Inset for a text field sitting inside a `Theme.bg2` box. iOS fields are text-height, so we
    /// pad all sides. Android's `TextField` maps to a Material `OutlinedTextField` that already has
    /// a ~56dp min-height + internal vertical padding, so we inset horizontally ONLY — otherwise
    /// our padding stacks on the field's and the box looks over-tall.
    @ViewBuilder
    func fieldBoxInset() -> some View {
        #if os(iOS)
        self.padding(Theme.Space.x3)
        #else
        self.padding(.horizontal, Theme.Space.x3)
        #endif
    }

    /// Inset for a tappable "menu box" — a `Menu` whose label is styled to look like a text field
    /// (Topic / Fee pickers). iOS pads all sides like a field. On Android `fieldBoxInset()` pads
    /// horizontally only (a real `TextField` brings its own ~56dp Material height), but a `Menu`
    /// label has NO intrinsic height, so it hugs its text and looks half as tall as the adjacent
    /// fields — here we add the field-matching min-height back.
    @ViewBuilder
    func menuFieldBox() -> some View {
        // Enforce a field-matching min-height on BOTH platforms (horizontal padding only): a `Menu`
        // HStack and a `Picker(.menu)` control have different intrinsic heights, so without a fixed
        // floor the Picker-backed box renders shorter than the Menu-backed one (and the text fields).
        #if os(iOS)
        self.padding(.horizontal, Theme.Space.x3).frame(minHeight: 48)
        #else
        self.padding(.horizontal, Theme.Space.x3).frame(minHeight: 56)
        #endif
    }

    /// Keep a label to one truncating line on iOS (tight rows wrap there). Android is gated
    /// out: `lineLimit` is on the historical Compose-crash modifier list (CLAUDE.md memory) and
    /// its rows already fit single-line.
    @ViewBuilder
    func singleLine() -> some View {
        #if os(iOS)
        self.lineLimit(1)
        #else
        self
        #endif
    }

    /// Cover the content whenever the scene isn't active — iOS can't block screenshots, but
    /// this keeps seeds out of the app switcher snapshot (§7). Android needs nothing here:
    /// `FLAG_SECURE` (PlatformBridge.setSecureScreen) already blanks capture AND the recents
    /// thumbnail.
    @ViewBuilder
    func obscuredWhenBackgrounded() -> some View {
        #if os(iOS)
        self.modifier(ObscuredWhenBackgrounded())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct ObscuredWhenBackgrounded: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if scenePhase != .active {
                ZStack {
                    Theme.Colors.bg0.ignoresSafeArea()
                    Logo(size: 72)
                }
            }
        }
    }
}
#endif
