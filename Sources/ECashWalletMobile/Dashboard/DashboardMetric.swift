// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The network metrics and their definitions — the ⓘ sheet's content. "Every metric has a
/// definition": the methodology is shown, not just the number (`docs/dashboard-plan.md` §3.5).
enum DashboardMetric: String, Identifiable, CaseIterable {
    case blockHeight, transactions24h, observedTPS, mempool

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .blockHeight: return "Block height"
        case .transactions24h: return "Transactions · 24h"
        case .observedTPS: return "Observed TPS"
        case .mempool: return "Mempool"
        }
    }

    /// The tile label — shorter where the full title would truncate in half a row.
    var shortTitle: LocalizedStringKey {
        switch self {
        case .transactions24h: return "Tx · 24h"
        default: return title
        }
    }

    var definition: LocalizedStringKey {
        switch self {
        case .blockHeight:
            return "The height of the newest block the explorer has accepted as the chain tip."
        case .transactions24h:
            return "Transactions in blocks whose timestamp falls in the last 24 hours, not counting each block's coinbase (the miner's reward)."
        case .observedTPS:
            return "Average confirmed throughput over the last day: transactions in the last 24 hours divided by 86,400 seconds. Not a capacity figure."
        case .mempool:
            return "Transactions the explorer's node has received but no block has confirmed yet."
        }
    }

    var source: String {
        switch self {
        case .blockHeight: return "GET /api/blocks/tip/height"
        case .transactions24h, .observedTPS: return "GET /api/v1/blocks"
        case .mempool: return "GET /api/mempool"
        }
    }

    var limitation: LocalizedStringKey {
        switch self {
        case .blockHeight:
            return "One explorer's view. A reorg can briefly change the tip."
        case .transactions24h, .observedTPS:
            return "Block timestamps are set by miners, so the 24-hour window is approximate. Test networks are not mainnet activity."
        case .mempool:
            return "Mempools differ between nodes; this is the explorer's."
        }
    }
}
