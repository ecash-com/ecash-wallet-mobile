// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// CoinNews fetch layer. Pure decode/map tests (canned proto3-JSON payloads, injected fetch — no
/// network) cover both backends + the proto3 "zero values are omitted" rule + the ConnectRPC error
/// envelope. A separate opt-in LIVE test hits a running BitWindow at :30301.
@Suite struct CoinNewsTests {

    private func cannedFetch(_ json: String, status: Int = 200) -> ConnectRPCClient.Fetch {
        let data = Data(json.utf8)
        return { _ in (data, status) }
    }

    private func endpoint() -> CoinNewsEndpoint {
        CoinNewsEndpoint(baseURL: URL(string: "http://127.0.0.1:30301")!, bearerToken: "test")
    }

    // MARK: - BitWindow misc.v1 (real observed payloads)

    @Test func bitWindowFeedDecodesAndMaps() async throws {
        // Item 2 has NO `content` (proto3 omits empty) → body must be nil.
        let json = """
        {"coinNews":[\
        {"id":"4","topic":"a1a1a1a1","headline":"Introducing SidΞcoin","content":"Bitcoin is a platform","feeSats":"133700","createTime":"2026-06-15T18:20:01Z"},\
        {"id":"3","topic":"a2a2a2a2","headline":"私はサトシです。","feeSats":"200","createTime":"2026-06-13T13:20:01Z"}\
        ]}
        """
        let client = BitWindowCoinNewsClient(endpoint: endpoint(), fetch: cannedFetch(json))
        let items = try await client.newFeed(limit: 50)

        #expect(items.count == 2)
        #expect(items[0].id == "4")
        #expect(items[0].topicHex == "a1a1a1a1")
        #expect(items[0].headline == "Introducing SidΞcoin")
        #expect(items[0].body == "Bitcoin is a platform")
        #expect(items[0].feeSats == 133_700)            // int64 came as a JSON string
        #expect(items[1].body == nil)                    // omitted content → nil
        #expect(items[1].headline == "私はサトシです。")  // unicode survives
        #expect(items[1].score == nil)                   // misc.v1 has no ranking
    }

    @Test func bitWindowLimitTruncates() async throws {
        let json = """
        {"coinNews":[{"id":"1","topic":"a1a1a1a1","headline":"one"},{"id":"2","topic":"a1a1a1a1","headline":"two"}]}
        """
        let client = BitWindowCoinNewsClient(endpoint: endpoint(), fetch: cannedFetch(json))
        #expect(try await client.newFeed(limit: 1).count == 1)
    }

    @Test func bitWindowTopicsDecodeAndMap() async throws {
        let json = """
        {"topics":[\
        {"id":"5","topic":"a1a1a1a1","name":"US Weekly","retentionDays":7,"confirmed":true},\
        {"id":"6","topic":"a2a2a2a2","name":"Japan Weekly","retentionDays":7}\
        ]}
        """
        let client = BitWindowCoinNewsClient(endpoint: endpoint(), fetch: cannedFetch(json))
        let topics = try await client.topics()
        #expect(topics.count == 2)
        #expect(topics[0].topicHex == "a1a1a1a1")
        #expect(topics[0].name == "US Weekly")
        #expect(topics[0].retentionDays == 7)
    }

    // MARK: - coinnews.v1 (production shape — ready for the public endpoint)

    @Test func coinNewsV1FrontPageDecodesAndMaps() async throws {
        // Second item is minimal — only itemIdHex + headline present (everything else omitted).
        let json = """
        {"items":[\
        {"itemIdHex":"0a1b2c","topicHex":"a1a1a1a1","headline":"Hello","body":"world","url":"https://e.x",\
         "score":12.5,"points":3,"commentCount":2,"blockHeight":940,"blockTime":"2026-06-15T18:20:01Z","authorXpkHex":"deadbeef"},\
        {"itemIdHex":"ff00","headline":"Minimal"}\
        ]}
        """
        let client = CoinNewsV1Client(endpoint: endpoint(), fetch: cannedFetch(json))
        let items = try await client.frontPage(limit: 50)

        #expect(items.count == 2)
        #expect(items[0].id == "0a1b2c")
        #expect(items[0].score == 12.5)
        #expect(items[0].points == 3)
        #expect(items[0].commentCount == 2)
        #expect(items[0].blockHeight == 940)
        #expect(items[0].authorXpkHex == "deadbeef")
        #expect(items[0].url == "https://e.x")
        #expect(items[1].id == "ff00")
        #expect(items[1].topicHex == "")     // omitted → default ""
        #expect(items[1].score == nil)        // omitted → nil
        #expect(items[1].body == nil)
    }

    // MARK: - ConnectRPC error envelope

    @Test func unauthenticatedSurfacesServerError() async throws {
        let json = #"{"code":"unauthenticated","message":"token invalid"}"#
        let client = BitWindowCoinNewsClient(endpoint: endpoint(), fetch: cannedFetch(json, status: 401))
        await #expect(throws: CoinNewsError.server(status: 401, message: "token invalid")) {
            _ = try await client.newFeed(limit: 10)
        }
    }

    // MARK: - LIVE (opt-in): hit a running BitWindow on :30301

    /// Run with `COINNEWS_LIVE=1 swift test --filter liveBitWindowFeed` while BitWindow is running.
    /// Reads BitWindow's local `.auth.cookie` for the bearer token. No-op (passes) when not opted-in.
    @Test func liveBitWindowFeed() async throws {
        guard ProcessInfo.processInfo.environment["COINNEWS_LIVE"] == "1" else { return }

        let cookiePath = ("~/Library/Application Support/bitwindow/.auth.cookie" as NSString).expandingTildeInPath
        let token = (try? String(contentsOfFile: cookiePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(token?.isEmpty == false)

        let endpoint = CoinNewsEndpoint(baseURL: URL(string: "http://127.0.0.1:30301")!, bearerToken: token)
        let client = BitWindowCoinNewsClient(endpoint: endpoint)

        let topics = try await client.topics()
        let feed = try await client.newFeed(limit: 50)
        print("CoinNews LIVE: \(topics.count) topics, \(feed.count) items — first: \(feed.first?.headline ?? "(none)")")
        #expect(!feed.isEmpty)
    }

    /// LIVE (opt-in): the public `coinnews.v1` signet indexer. Run with
    /// `COINNEWS_V1_LIVE=1 swift test --filter liveCoinNewsV1Feed`. No auth. No-op when not opted-in.
    @Test func liveCoinNewsV1Feed() async throws {
        guard ProcessInfo.processInfo.environment["COINNEWS_V1_LIVE"] == "1" else { return }

        let endpoint = CoinNewsEndpoint(baseURL: URL(string: "https://coinnews.signet.dc.galaxoidlabs.com")!)
        let client = CoinNewsV1Client(endpoint: endpoint)

        let topics = try await client.topics()
        let feed = try await client.frontPage(limit: 50)
        print("coinnews.v1 LIVE: \(topics.count) topics, \(feed.count) items — first: \(feed.first?.headline ?? "(none)")")
        #expect(!feed.isEmpty)        // signet has seeded stories
        #expect(feed.allSatisfy { !$0.id.isEmpty && !$0.headline.isEmpty })
    }
}
