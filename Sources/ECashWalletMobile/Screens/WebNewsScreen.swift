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

    /// Used to hand outbound links to the system browser — see `ExternalLinkDelegate`.
    @Environment(\.openURL) var openURL

    #if os(iOS) || os(Android)
    /// Held in `@State` so the engine, its configuration and the delegate survive body
    /// re-evaluation instead of being rebuilt (which would reload the page).
    @State var navigator = WebViewNavigator()
    @State var state = WebViewState()
    @State var configuration = WebEngineConfiguration()
    @State var linkDelegate = ExternalLinkDelegate()
    #endif

    var body: some View {
        content
            .navigationTitle(Text("eCash.com News", bundle: .module, comment: "web news screen title"))
            .inlineNavigationTitle()
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS) || os(Android)
        WebView(configuration: configuration, navigator: navigator, url: url, state: $state)
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                // Wired here rather than at construction because the handler needs `openURL` from the
                // environment. Both are reference types, so assigning after the WebView was built
                // still takes effect.
                linkDelegate.open = { openURL($0) }
                configuration.uiDelegate = linkDelegate
            }
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
}

#if os(iOS) || os(Android)
/// Sends `target="_blank"` links to the system browser instead of opening them in this view.
///
/// Two problems, one fix. First the links did nothing at all: a new-window request goes to
/// `createWebViewWith` (`WKUIDelegate` / `WebChromeClient.onCreateWindow`) and SkipWeb's default
/// answer is `nil` — deny — so every outbound link on the news site was inert.
///
/// Second, loading them in place is worse than it sounds. This screen deliberately has no browser
/// chrome: no back, forward, or reload. Follow a link two pages deep and the only way out is the
/// navigation back button, which pops the entire screen and loses your place. Handing outbound links
/// to the real browser gives the user history, tabs and share for free, and leaves this view showing
/// the one page it exists to show.
@MainActor
final class ExternalLinkDelegate: SkipWebUIDelegate {
    /// Set by the view from `@Environment(\.openURL)`.
    var open: ((URL) -> Void)?

    // `nonisolated` to match the protocol requirement. Both platforms deliver this callback on the
    // main thread, so `assumeIsolated` states a fact rather than hopping through a Task — which
    // Swift 6 would reject anyway for carrying non-Sendable state across the boundary.
    nonisolated func webView(_ webView: WebView, createWebViewWith request: WebWindowRequest,
                             platformContext: PlatformCreateWindowContext) -> WebEngine? {
        // Android may not know the target URL at onCreateWindow time (documented in SkipWeb). Without
        // a destination there's nothing useful to do, so decline rather than guess.
        guard let target = request.targetURL else { return nil }
        MainActor.assumeIsolated { self.open?(target) }
        return nil   // never create a child view — the system browser owns it now
    }
}
#endif
