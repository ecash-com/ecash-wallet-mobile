// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A compact CoinNews story for the dashboard: headline, then points · comments · topic. The full
/// row (with body and markdown) is `NewsRow`, on the Coin News screen.
struct CoinNewsPreviewRow: View {
    let item: CoinNewsItem
    let topicName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.headline)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(verbatim: meta)
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: String {
        var parts: [String] = []
        if let points = item.points { parts.append("▲ \(points)") }
        if let comments = item.commentCount { parts.append("\(comments) comments") }
        if let topicName { parts.append(topicName) }
        return parts.joined(separator: " · ")
    }
}
