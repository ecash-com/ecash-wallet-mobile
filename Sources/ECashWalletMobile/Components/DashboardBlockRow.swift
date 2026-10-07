// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One block in Latest blocks: height and age, then tx count · size · miner.
struct DashboardBlockRow: View {
    let block: DashboardBlock
    let now: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DashboardFormat.integer(block.height))
                    .font(.jbMono(14, .medium))
                    .foregroundStyle(Theme.Colors.text0)
                Text(verbatim: block.miner ?? "Unknown miner")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(DashboardFormat.integer(block.txCount)) tx", bundle: .module,
                     comment: "block row: transaction count; %@ is a number")
                    .font(.jbMono(13, .regular))
                    .foregroundStyle(Theme.Colors.text1)
                Text(verbatim: "\(DashboardFormat.bytes(block.sizeBytes)) · \(DashboardFormat.age(since: block.timestamp, now: now))")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
            }
        }
    }
}
