// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One block as the dashboard shows it (Latest blocks, Activity bars).
struct DashboardBlock: Equatable, Codable, Sendable, Identifiable {
    let hash: String
    let height: Int64
    /// Header time, epoch seconds. Miner-supplied — not strictly increasing, and not a wall clock.
    let timestamp: Int64
    /// Including the coinbase, as the explorer reports it.
    let txCount: Int64
    let sizeBytes: Int64
    /// Pool label from the explorer ("avonpool"); nil when it doesn't know. May be incomplete.
    let miner: String?

    var id: String { hash }

    /// Transactions a user sent — the coinbase isn't one.
    var nonCoinbaseTxCount: Int64 { max(txCount - 1, 0) }
}

/// The network section's data: the chain tip, recent blocks, and the 24-hour derivations.
/// Every number here has a definition in `DashboardMetric`.
struct ChainSnapshot: Equatable, Codable, Sendable {
    let tipHeight: Int64
    /// Newest first. At least the last 24 blocks when the chain has them, plus however many more the
    /// 24-hour window needed.
    let blocks: [DashboardBlock]
    /// Non-coinbase transactions in blocks whose header time falls in the last 24 hours.
    let transactions24h: Int64
    /// Pending transactions in the explorer's mempool.
    let mempoolCount: Int64
    let mempoolVSize: Int64

    /// Average confirmed throughput over the day: `transactions24h ÷ 86,400`. The reference
    /// dashboard's definition, so the two agree.
    var observedTPS: Double { Double(transactions24h) / Double(ChainSnapshot.windowSeconds) }

    static let windowSeconds: Int64 = 86_400

    /// Blocks the Activity chart draws.
    static let barCount = 24

    /// Σ non-coinbase tx over blocks with `timestamp ≥ now − 24h`. Header times are miner-supplied
    /// and can be out of order, so this filters by time rather than stopping at the first old block.
    static func transactionsInWindow(_ blocks: [DashboardBlock], now: Int64) -> Int64 {
        let cutoff = now - windowSeconds
        var total: Int64 = 0
        for block in blocks where block.timestamp >= cutoff { total += block.nonCoinbaseTxCount }
        return total
    }
}
