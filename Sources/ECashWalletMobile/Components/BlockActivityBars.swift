// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Transactions per block for the last `ChainSnapshot.barCount` blocks, oldest on the left. Plain
/// `Rectangle`s with computed heights — Skip has no `Canvas`. Bars are scaled to the busiest block in
/// view; an empty block still gets a 2-pt sliver so the gap reads as "a block with nothing in it".
struct BlockActivityBars: View {
    let blocks: [DashboardBlock]
    var height: CGFloat = 56

    var body: some View {
        let shown = Array(blocks.prefix(ChainSnapshot.barCount).reversed())
        let peak = max(shown.map(\.nonCoinbaseTxCount).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(shown) { block in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Colors.accent)
                    .frame(height: max(2, height * CGFloat(block.nonCoinbaseTxCount) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityLabel(Text("Transactions per block, last \(shown.count) blocks", bundle: .module,
                                 comment: "dashboard activity chart accessibility; %lld is a count"))
    }
}
