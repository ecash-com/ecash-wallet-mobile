// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// "Deposit to Thunder", or "Sidechain deposit · slot 9" when the name isn't known yet (offline, or
/// a network without an enforcer). Shared by the Activity row and the tx detail hero.
struct SidechainDepositTitle: View {
    let name: String?
    let slot: Int32
    /// True on the sidechain side (a Thunder wallet): the deposit ARRIVED here.
    var received = false

    var body: some View {
        if received {
            Text("Deposit received", bundle: .module,
                 comment: "tx title in a sidechain wallet: coins deposited in from the mainchain")
        } else if let name {
            Text("Deposit to \(name)", bundle: .module, comment: "tx title: deposit into a sidechain; %@ is its name")
        } else {
            Text("Sidechain deposit · slot \(String(slot))", bundle: .module,
                 comment: "tx title: deposit into a sidechain whose name isn't known; %@ is the slot")
        }
    }
}
