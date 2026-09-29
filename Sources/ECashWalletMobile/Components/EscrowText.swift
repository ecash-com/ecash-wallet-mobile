// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// What a sidechain holds on the mainchain, or that nobody has deposited yet.
struct EscrowText: View {
    let treasury: SidechainTreasury?
    let unitLabel: String

    var body: some View {
        if let treasury {
            Text("\(Amount(sats: treasury.valueSats).formattedCoin()) \(unitLabel) in escrow",
                 bundle: .module, comment: "sidechain escrow; %1$@ amount, %2$@ unit")
                .foregroundStyle(Theme.Colors.text0)
        } else {
            Text("No deposits yet", bundle: .module, comment: "sidechain with an empty escrow")
                .foregroundStyle(Theme.Colors.text2)
        }
    }
}
