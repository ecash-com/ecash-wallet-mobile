// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The full eCash.com news timeline (`news.ecash.com/rss.xml`), newest first. Each item opens its
/// link in the system browser — these are mostly third-party sites, so we don't embed them.
struct EcosystemNewsScreen: View {
    @Environment(AppState.self) var app

    var body: some View {
        let section = app.dashboard.news
        List {
            Section(footer: DashboardFreshness(updatedAt: section.updatedAt, stale: section.lastAttemptFailed,
                                               source: "news.ecash.com")) {
                ForEach(section.value ?? []) { item in
                    row(item)
                }
            }
            .listRowBackground(Theme.Colors.bg2)
        }
        .groupedListStyle()
        .themedGroupedListBackground()
        .refreshable { await app.dashboard.refresh(force: true) }
        // Pushing this screen cancels the Dashboard root's refresh loop, so catch up here.
        .task { await app.dashboard.refresh() }
        .navigationTitle(Text("eCash News", bundle: .module, comment: "ecosystem news screen title"))
        .inlineNavigationTitle()
    }

    @ViewBuilder private func row(_ item: EcosystemNewsItem) -> some View {
        if let url = URL(string: item.link) {
            Link(destination: url) {
                EcosystemNewsRow(item: item, showSummary: true).padding(.vertical, Theme.Space.x1)
            }
            .buttonStyle(.plain)
        } else {
            EcosystemNewsRow(item: item, showSummary: true).padding(.vertical, Theme.Space.x1)
        }
    }
}
