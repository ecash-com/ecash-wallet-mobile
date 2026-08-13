// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The News tab's root — a chooser between the two kinds of news the app can show:
///
///   • **Coin News** — the on-chain bulletin board for the selected wallet's network. Per-network,
///     written by users, read from the `coinnews.v1` indexer.
///   • **eCash.com News** — the project's own site, an ordinary web page in an embedded browser.
///
/// **The chooser only exists when there's a choice.** CoinNews is per-network (`CoinNewsAvailability`
/// — off on Bitcoin mainnet, on where an indexer resolves), so on a network without it this view is
/// just the web news, with no pointless menu in front of it. That's why the tab is now always
/// present: it used to be hidden entirely when CoinNews was unavailable, but eCash.com news is worth
/// reading on any network.
struct NewsHubScreen: View {
    @Environment(AppState.self) var app

    /// The project's news site. Not in `NetworkRegistry` on purpose — it's one URL for the product,
    /// not a per-network endpoint like the indexers and explorers.
    static let ecashNewsURL = URL(string: "https://news.ecash.com/")!

    var body: some View {
        if app.coinNewsAvailable {
            chooser
        } else {
            // Nothing to choose between — go straight to the web news.
            WebNewsScreen(url: Self.ecashNewsURL)
        }
    }

    /// Display name of the selected wallet's network, for the Coin News blurb — CoinNews is
    /// per-network, and saying which one avoids implying it's a single global feed.
    private var networkName: String {
        guard let network = app.selectedWallet?.network else { return "this network" }
        return NetworkRegistry.params(for: network).displayName
    }

    private var chooser: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(spacing: Theme.Space.x4) {
                NewsHubCard(
                    icon: Icon.news,
                    title: "Coin News",
                    subtitle: "On-chain posts from \(networkName). Written to the blockchain, readable by anyone.",
                    route: NewsRoute.coinNews)

                NewsHubCard(
                    icon: Icon.link,
                    title: "eCash.com News",
                    subtitle: "Announcements and updates from the eCash project.",
                    route: NewsRoute.web)

                Spacer()
            }
            .padding(Theme.Space.gutter)
        }
        .navigationTitle(Text("News", bundle: .module, comment: "news hub title"))
        .navigationDestination(for: NewsRoute.self) { route in
            switch route {
            case .coinNews: NewsScreen()
            case .web: WebNewsScreen(url: Self.ecashNewsURL)
            }
        }
    }
}

enum NewsRoute: Hashable {
    case coinNews
    case web
}

/// One tappable option on the News hub: accent glyph, title, a line of explanation, disclosure arrow.
/// `internal`, not `private` — Fuse bridges views to Android and a private view can't be bridged.
struct NewsHubCard: View {
    let icon: Icon
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let route: NewsRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: Theme.Space.x3) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Colors.accentTint)
                    Image(icon: icon)
                        .resizable().scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text(title, bundle: .module)
                        .font(.grotesk(17, .semibold))
                        .foregroundStyle(Theme.Colors.text0)
                    Text(subtitle, bundle: .module)
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: Theme.Space.x2)

                Image(icon: Icon.disclosure)
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
    }
}
