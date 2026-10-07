// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// The network section: paging back to cover 24 hours, and the derived numbers (tx 24h excludes each
/// coinbase; TPS is tx 24h ÷ 86,400 — the reference dashboard's definition).
@Suite struct ChainStatsClientTests {
    static let base = "https://explorer.test"
    static let network = DashboardNetwork(id: "testnet", displayName: "Test", explorerURL: base, releasesChannel: "testnet")
    static let now: Int64 = 1_000_000

    /// `count` blocks from `topHeight` down, one every `spacing` seconds ending at `now - offset`.
    static func page(topHeight: Int64, count: Int, newestTime: Int64, spacing: Int64, txCount: Int64 = 101) -> String {
        let rows = (0..<count).map { i -> String in
            let h = topHeight - Int64(i)
            let t = newestTime - Int64(i) * spacing
            return """
            {"id":"hash\(h)","height":\(h),"timestamp":\(t),"tx_count":\(txCount),"size":2048,
             "extras":{"pool":{"id":1,"name":"avonpool","slug":"avonpool"}}}
            """
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    @Test func pagesBackUntilTheWindowIsCoveredAndDerivesTheDay() async throws {
        let web = FakeDashboardWeb()
        web.on("\(Self.base)/api/blocks/tip/height", "500\n")
        // One block per hour: 10 per page, so the 24 h window needs pages 1–3.
        let hour: Int64 = 3_600
        web.on("\(Self.base)/api/v1/blocks", Self.page(topHeight: 500, count: 10, newestTime: Self.now - 60, spacing: hour))
        web.on("\(Self.base)/api/v1/blocks/490", Self.page(topHeight: 490, count: 10, newestTime: Self.now - 60 - 10 * hour, spacing: hour))
        web.on("\(Self.base)/api/v1/blocks/480", Self.page(topHeight: 480, count: 10, newestTime: Self.now - 60 - 20 * hour, spacing: hour))
        web.on("\(Self.base)/api/mempool", #"{"count":1627,"vsize":324143,"total_fee":1085548,"fee_histogram":[]}"#)

        let snapshot = try await ChainStatsClient(network: Self.network, fetch: web.fetch).snapshot(now: Self.now)

        #expect(snapshot.tipHeight == 500)
        #expect(snapshot.blocks.count == 30)
        #expect(!web.requested.contains("\(Self.base)/api/v1/blocks/470"))   // stopped once covered
        // Blocks at now-60 … now-60-23h are inside the window: 24 blocks × 100 non-coinbase tx.
        #expect(snapshot.transactions24h == 2_400)
        #expect(abs(snapshot.observedTPS - 2_400.0 / 86_400.0) < 1e-12)
        #expect(snapshot.mempoolCount == 1_627)
        #expect(snapshot.blocks.first?.miner == "avonpool")
    }

    @Test func theWindowFiltersByTimestampNotOrder() {
        // Miner timestamps can go backwards; a block inside the window after an old one still counts.
        func block(_ h: Int64, _ t: Int64, _ tx: Int64) -> DashboardBlock {
            DashboardBlock(hash: "\(h)", height: h, timestamp: t, txCount: tx, sizeBytes: 1, miner: nil)
        }
        let blocks = [block(3, Self.now - 100, 11), block(2, Self.now - 90_000, 50), block(1, Self.now - 200, 6)]
        #expect(ChainSnapshot.transactionsInWindow(blocks, now: Self.now) == 15)   // 10 + 5, coinbases removed
    }

    @Test func aBlockWithOnlyItsCoinbaseCountsZero() {
        let block = DashboardBlock(hash: "h", height: 1, timestamp: 0, txCount: 1, sizeBytes: 1, miner: nil)
        #expect(block.nonCoinbaseTxCount == 0)
        let empty = DashboardBlock(hash: "h", height: 1, timestamp: 0, txCount: 0, sizeBytes: 1, miner: nil)
        #expect(empty.nonCoinbaseTxCount == 0)
    }

    @Test func pagingIsCappedOnAChainThatNeverLeavesTheWindow() async throws {
        let web = FakeDashboardWeb()
        web.on("\(Self.base)/api/blocks/tip/height", "1000")
        // Every block stamped "now": the window is never exceeded, so only the cap stops paging.
        for page in 0..<30 {
            let top = Int64(1000 - page * 10)
            let path = page == 0 ? "/api/v1/blocks" : "/api/v1/blocks/\(top)"
            web.on("\(Self.base)\(path)", Self.page(topHeight: top, count: 10, newestTime: Self.now, spacing: 0))
        }
        web.on("\(Self.base)/api/mempool", #"{"count":0,"vsize":0}"#)
        let snapshot = try await ChainStatsClient(network: Self.network, fetch: web.fetch).snapshot(now: Self.now)
        #expect(snapshot.blocks.count == ChainStatsClient.maxPages * 10)
    }

    @Test func aMissingPoolLabelIsNil() throws {
        let json = #"[{"id":"a","height":1,"timestamp":1,"tx_count":2,"size":3,"extras":{"pool":{"name":"  "}}},{"id":"b","height":0,"timestamp":1,"tx_count":2,"size":3}]"#
        let rows = try JSONDecoder().decode([ExplorerBlock].self, from: Data(json.utf8)).map(\.dashboardBlock)
        #expect(rows.map(\.miner) == [nil, nil])
    }

    @Test func aBadTipFailsTheSection() async {
        let web = FakeDashboardWeb()
        web.on("\(Self.base)/api/blocks/tip/height", "oops")
        await #expect(throws: DashboardError.malformed("blocks/tip/height")) {
            try await ChainStatsClient(network: Self.network, fetch: web.fetch).snapshot(now: Self.now)
        }
    }
}
