// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The eCash.com news feed. RSS rather than the page itself: it's the project's own published feed,
/// so it's the stable interface (the site's HTML is not).
struct EcosystemNewsClient: Sendable {
    let fetch: DashboardFetch
    static let feedURL = "https://news.ecash.com/rss.xml"

    /// Newest first.
    func items() async throws -> [EcosystemNewsItem] {
        guard let url = URL(string: Self.feedURL) else { throw DashboardError.malformed("news url") }
        let data = try await DashboardHTTP.get(url, using: fetch)
        guard let xml = String(data: data, encoding: .utf8) else { throw DashboardError.malformed("news: not UTF-8") }
        let items = RSSFeedParser.items(from: xml)
        guard !items.isEmpty else { throw DashboardError.malformed("news: no items") }
        return items.sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
    }
}
