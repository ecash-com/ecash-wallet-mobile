// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One eCash.com news item: date column, title, and source · first category. `showSummary` adds the
/// two-line description on the full timeline. Tapping opens the link in the system browser (the
/// caller wraps it) — these are mostly third-party sites.
struct EcosystemNewsRow: View {
    let item: EcosystemNewsItem
    var showSummary = false

    var body: some View {
        // `.top`, not `.firstTextBaseline`: Compose ignores baseline alignment and centres the date
        // against a two-line title. A 2-pt nudge lines the smaller date up with the title's first line.
        HStack(alignment: .top, spacing: Theme.Space.x3) {
            Text(verbatim: item.publishedAt.map { DashboardFormat.dayMonth($0) } ?? "—")
                .font(.jbMono(12, .medium))
                .foregroundStyle(Theme.Colors.text2)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                Text(verbatim: item.title)
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if showSummary, !item.summary.isEmpty {
                    Text(verbatim: item.summary)
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text1)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if let meta = meta {
                    Text(verbatim: meta)
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                        .lineLimit(1)
                }
            }
        }
    }

    private var meta: String? {
        let parts = [item.source, item.categories.first].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
