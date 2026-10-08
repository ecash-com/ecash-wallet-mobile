// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Reads the network section from the chain explorer's public API — the mempool-style explorer in
/// front of the eCash node (`explorer.beta.ecash.ninja`). Three routes:
///
///   * `GET /api/blocks/tip/height` — the tip, as plain text
///   * `GET /api/v1/blocks[/{height}]` — 10 blocks per page, newest first, with the pool label
///   * `GET /api/mempool` — pending count and vsize
///
/// Pages back until the 24-hour window is covered. Betanet's blocks are irregular (minutes to an
/// hour apart), so that's usually one to three pages; `maxPages` bounds a pathological chain.
struct ChainStatsClient: Sendable {
    let network: DashboardNetwork
    let fetch: DashboardFetch
    static let maxPages = 20

    func snapshot(now: Int64) async throws -> ChainSnapshot {
        let base = network.explorerURL
        let tipData = try await DashboardHTTP.get(try DashboardHTTP.url(base, "/api/blocks/tip/height"), using: fetch)
        guard let tipText = String(data: tipData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let tip = Int64(tipText) else { throw DashboardError.malformed("blocks/tip/height") }

        var blocks: [DashboardBlock] = []
        var path = "/api/v1/blocks"
        for _ in 0..<Self.maxPages {
            let page = try await DashboardHTTP.decode([ExplorerBlock].self, from: try DashboardHTTP.url(base, path),
                                                      using: fetch, route: "v1/blocks")
            guard !page.isEmpty else { break }
            blocks += page.map(\.dashboardBlock)
            guard let oldest = page.last, oldest.height > 0 else { break }
            if Self.coversWindow(blocks, now: now) { break }
            path = "/api/v1/blocks/\(oldest.height - 1)"
        }

        let mempool = try await DashboardHTTP.decode(ExplorerMempool.self,
                                                     from: try DashboardHTTP.url(base, "/api/mempool"),
                                                     using: fetch, route: "mempool")
        return ChainSnapshot(tipHeight: tip, blocks: blocks,
                             transactions24h: ChainSnapshot.transactionsInWindow(blocks, now: now),
                             mempoolCount: mempool.count, mempoolVSize: mempool.vsize)
    }

    /// Enough fetched: the chart's bars, and a block older than the window (so nothing in the window
    /// is still unfetched).
    static func coversWindow(_ blocks: [DashboardBlock], now: Int64) -> Bool {
        guard blocks.count >= ChainSnapshot.barCount, let oldest = blocks.last else { return false }
        return oldest.timestamp < now - ChainSnapshot.windowSeconds
    }
}

/// `/api/v1/blocks` row — only the fields we use; the rest is ignored.
struct ExplorerBlock: Decodable {
    let id: String
    let height: Int64
    let timestamp: Int64
    let txCount: Int64
    let size: Int64
    let extras: Extras?

    struct Extras: Decodable { let pool: Pool? }
    struct Pool: Decodable { let name: String? }

    enum CodingKeys: String, CodingKey {
        case id, height, timestamp, size, extras
        case txCount = "tx_count"
    }

    var dashboardBlock: DashboardBlock {
        // The explorer writes a literal "Unknown" for an unidentified pool — that's no label, not a name.
        var pool = extras?.pool?.name?.trimmingCharacters(in: .whitespaces)
        if let name = pool, name.isEmpty || name.lowercased() == "unknown" { pool = nil }
        return DashboardBlock(hash: id, height: height, timestamp: timestamp, txCount: txCount, sizeBytes: size,
                              miner: pool)
    }
}

struct ExplorerMempool: Decodable {
    let count: Int64
    let vsize: Int64
}
