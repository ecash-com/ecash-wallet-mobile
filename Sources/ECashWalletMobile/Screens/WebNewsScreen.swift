// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
#if os(iOS) || os(Android)
import SkipWeb
#endif

/// The eCash.com news site, embedded. `SkipWeb.WebView` is a real SwiftUI view (WKWebView on iOS,
/// `android.webkit.WebView` on Android), so it pushes into the News stack like any other screen
/// rather than throwing the user out to Safari — they keep the tab bar and the back button.
///
/// The `os(iOS) || os(Android)` gate is required, not defensive: SkipWeb declares `WebView` under
/// `#if SKIP || os(iOS)`, so it does not exist in the **macOS host** build that runs our tests and
/// drives transpilation. Without the gate, `swift test` fails with "cannot find 'WebView' in scope"
/// even though both shipping platforms are fine.
///
/// Deliberately a plain page view: this is content we don't own, so we render it and stay out of the
/// way. No wallet state is exposed to the page and nothing is injected into it.
struct WebNewsScreen: View {
    let url: URL

    /// Hands outbound links to the system browser — see `opensExternally(_:)`.
    @Environment(\.openURL) var openURL

    #if os(iOS) || os(Android)
    /// Held in `@State` so the engine and its configuration survive body re-evaluation instead of
    /// being rebuilt (which would reload the page).
    @State var navigator = WebViewNavigator()
    @State var state = WebViewState()
    @State var configuration = WebEngineConfiguration()
    #endif

    var body: some View {
        content
            .navigationTitle(Text("eCash.com News", bundle: .module, comment: "web news screen title"))
            .inlineNavigationTitle()
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS) || os(Android)
        let web = WebView(configuration: configuration,
                          navigator: navigator,
                          url: url,
                          state: $state,
                          shouldOverrideUrlLoading: { candidate in
                              guard opensExternally(candidate) else { return false }
                              openURL(candidate)
                              return true   // true = "we handled it"; the web view does not navigate
                          })
        #if os(Android)
        // No `ignoresSafeArea` here. Extending the page under the bottom inset let the web content
        // draw through the tab bar, which rendered transparent — its items were still visible and
        // tappable, but the bar had no background. Letting the safe area do its job gives the bar
        // back its own surface to draw on.
        web
        #else
        // iOS keeps it: the page runs to the bottom edge under the home indicator, and UIKit still
        // composites the tab bar opaquely above it.
        web.ignoresSafeArea(edges: .bottom)
        #endif
        #else
        // macOS host only (tests / transpile target) — never a shipping path.
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            Text(verbatim: url.absoluteString)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text2)
        }
        #endif
    }

    /// Whether a navigation should leave the app for the system browser: anything off the news site's
    /// own host.
    ///
    /// **Why links leave at all.** This screen deliberately has no browser chrome — no back, forward,
    /// or reload. Follow a link two pages deep in place and the only way out is the navigation back
    /// button, which pops the whole screen and loses your place. The real browser brings history, tabs
    /// and share for free, and leaves this view showing the one page it exists to show.
    ///
    /// **Why by host, and not "everything but the first page".** This hook fires for the initial load
    /// and for any redirect it goes through, not just for taps — a blanket rule would fling the user
    /// into the browser the instant the screen opened. Comparing hosts can't do that: our own page and
    /// any same-site redirect stay put no matter what. It also can't be tripped by a subframe, since
    /// SkipWeb consults this before checking whether the navigation is main-frame (verified: the site
    /// is a React SPA with no iframes; the only `iframe` strings in its bundle are React's own DOM
    /// event registration, and its YouTube references are `watch?v=` links, not embedded players).
    ///
    /// Scheme links (`mailto:`, `tel:`) have no host, so they fall to the system too — which is
    /// exactly where they belong.
    private func opensExternally(_ candidate: URL) -> Bool {
        guard let target = candidate.host, let own = url.host else { return true }
        return target.caseInsensitiveCompare(own) != .orderedSame
    }
}
