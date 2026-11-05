// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Prices with venue and volume, plus where the numbers come from. Rows aren't tappable: no links to
/// trading venues (App Review 3.1.5 — `docs/dashboard-plan.md` §3.6).
struct MarketsScreen: View {
    @Environment(AppState.self) var app

    var body: some View {
        let section = app.dashboard.markets
        List {
            Section(header: header(Text("Bitcoin and its forks", bundle: .module, comment: "markets: comparison section")),
                    footer: footnote(section)) {
                ForEach(section.value?.quotes ?? []) { quote in
                    MarketRow(quote: quote, detailed: true)
                }
            }
            .listRowBackground(Theme.Colors.bg2)
        }
        .groupedListStyle()
        .themedGroupedListBackground()
        .refreshable { await app.dashboard.refresh(force: true) }
        // Pushing this screen cancels the Dashboard root's refresh loop, so catch up here.
        .task { await app.dashboard.refresh() }
        .navigationTitle(Text("Markets", bundle: .module, comment: "markets screen title"))
        .inlineNavigationTitle()
    }

    private func header(_ text: Text) -> some View {
        text.textStyle(.overline).foregroundStyle(Theme.Colors.text2)
    }

    private func footnote(_ section: DashboardSection<MarketBoard>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text("Prices in USDT on Gate.io and NonKYC. ECX is priced from the wECX pool on Orca (Solana), shown on the Dashboard.",
                 bundle: .module, comment: "markets footnote: sources, and where the ECX price comes from")
            DashboardFreshness(updatedAt: section.updatedAt, stale: section.lastAttemptFailed)
        }
        .textStyle(.xs)
        .foregroundStyle(Theme.Colors.text2)
    }
}
