// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One item from the eCash.com news feed (`news.ecash.com/rss.xml`): listings, releases, interviews,
/// podcasts. Not CoinNews — that's the on-chain board, a separate section.
struct EcosystemNewsItem: Equatable, Codable, Sendable, Identifiable {
    /// The RSS `guid` (stable), falling back to the link.
    let id: String
    let title: String
    /// Where the item points — usually a third-party site. Opened in the system browser.
    let link: String
    /// `pubDate` as epoch seconds; nil when the feed's date doesn't parse.
    let publishedAt: Int64?
    let summary: String
    /// Who published it ("CoinCarp"), from `<source>`.
    let source: String?
    let categories: [String]
}
