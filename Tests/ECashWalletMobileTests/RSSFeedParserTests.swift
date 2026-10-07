// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// The eCash.com news feed parser, against the live feed's shape (first two items, 2026-10-07).
@Suite struct RSSFeedParserTests {
    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>eCash News</title>
        <link>https://news.ecash.com</link>
        <atom:link href="https://news.ecash.com/rss.xml" rel="self" type="application/rss+xml" />
        <ttl>15</ttl>
        <item>
          <title>CoinCarp Adds eCash (ECX) Ahead of Mainnet</title>
          <link>https://www.coincarp.com/currencies/ecashdotcom/</link>
          <guid isPermaLink="false">https://news.ecash.com/#coincarp-adds-ecash-ecx-ahead-of-mainnet</guid>
          <pubDate>Mon, 05 Oct 2026 12:00:00 GMT</pubDate>
          <description>CoinCarp has added a dedicated eCash (ECX) profile.</description>
          <source url="https://news.ecash.com">CoinCarp</source>
          <category>Market Data</category>
          <category>Markets</category>
        </item>
        <item>
          <title>Sidecoin Ships First Mobile Wallet Release for eCash Drivechains</title>
          <link>https://github.com/APECSdev/sidecoin/commit/f42a174</link>
          <guid isPermaLink="false">https://news.ecash.com/#sidecoin</guid>
          <pubDate>Fri, 02 Oct 2026 12:00:00 GMT</pubDate>
          <description>Sidecoin &amp; friends &#8212; &quot;drivechains&quot; &lt;BIP-300&gt;</description>
          <source url="https://news.ecash.com">Sidecoin</source>
          <category>Ecosystem</category>
        </item>
      </channel>
    </rss>
    """

    @Test func readsEveryItemField() throws {
        let items = RSSFeedParser.items(from: Self.feed)
        #expect(items.count == 2)
        let first = try #require(items.first)
        #expect(first.title == "CoinCarp Adds eCash (ECX) Ahead of Mainnet")
        #expect(first.link == "https://www.coincarp.com/currencies/ecashdotcom/")
        #expect(first.id == "https://news.ecash.com/#coincarp-adds-ecash-ecx-ahead-of-mainnet")
        #expect(first.publishedAt == 1_791_201_600)   // 2026-10-05T12:00:00Z
        #expect(first.source == "CoinCarp")
        #expect(first.categories == ["Market Data", "Markets"])
    }

    @Test func theChannelTitleIsNotAnItem() {
        #expect(!RSSFeedParser.items(from: Self.feed).contains { $0.title == "eCash News" })
    }

    @Test func entitiesDecode() {
        let items = RSSFeedParser.items(from: Self.feed)
        #expect(items[1].summary == "Sidecoin & friends \u{2014} \"drivechains\" <BIP-300>")
    }

    @Test func cdataIsLiteral() {
        let xml = "<item><title><![CDATA[Fish &amp; Chips <b>]]></title><guid>g</guid></item>"
        #expect(RSSFeedParser.items(from: xml).first?.title == "Fish &amp; Chips <b>")
    }

    @Test func missingLinkFallsBackToGuid() {
        let xml = "<item><title>T</title><guid>https://news.ecash.com/#t</guid></item>"
        let item = RSSFeedParser.items(from: xml).first
        #expect(item?.link == "https://news.ecash.com/#t")
        #expect(item?.publishedAt == nil)
    }

    @Test func aTagPrefixIsNotTheTag() {
        // `<sourceId>` must not be read as `<source>`.
        let block = "<sourceId>x</sourceId><source url=\"u\">Real</source>"
        #expect(RSSFeedParser.element("source", in: block) == "Real")
    }

    @Test func itemsWithoutATitleAreSkipped() {
        #expect(RSSFeedParser.items(from: "<item><link>x</link></item>").isEmpty)
    }

    @Test func clientSortsNewestFirst() async throws {
        let web = FakeDashboardWeb()
        let reversed = Self.feed.replacingOccurrences(of: "Mon, 05 Oct", with: "Thu, 01 Oct")
        web.on(EcosystemNewsClient.feedURL, reversed)
        let items = try await EcosystemNewsClient(fetch: web.fetch).items()
        #expect(items.map(\.source) == ["Sidecoin", "CoinCarp"])
    }
}
