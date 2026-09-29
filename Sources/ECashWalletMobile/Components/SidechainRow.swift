// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// One active sidechain: name + slot, the declared description, and its escrow.
struct SidechainRow: View {
    let entry: SidechainsViewModel.Entry
    let unitLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: entry.sidechain.title)
                    .textStyle(.h3)
                    .foregroundStyle(Theme.Colors.text0)
                Spacer()
                SlotLabel(slot: entry.sidechain.slot)
            }
            if !entry.sidechain.description.isEmpty {
                Text(verbatim: entry.sidechain.description)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
                    .lineLimit(2)
            }
            EscrowText(treasury: entry.treasury, unitLabel: unitLabel)
                .textStyle(.xs)
        }
        .padding(.vertical, Theme.Space.x1)
    }
}
