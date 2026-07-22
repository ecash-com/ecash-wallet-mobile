// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Network chooser for the create / import flows. A wallet's network is fixed at creation because
/// mainnet (coin-type `0'`) and the testnet-class networks (coin-type `1'`) derive different
/// addresses from the same seed (Golden Rule §4) — so this is a real, up-front choice, not a
/// switchable view. Defaults to a testnet-class network so **mainnet is never auto-selected**
/// (Golden Rule §6); picking Bitcoin swaps the safety chip for an explicit real-money warning.
struct NetworkSelector: View {
    @Binding var network: WalletNetwork

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("Network", bundle: .module, comment: "network selector label")
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)

            Picker("Network", selection: $network) {
                ForEach(WalletNetwork.selectable, id: \.self) { net in
                    Text(verbatim: NetworkRegistry.params(for: net).displayName).tag(net)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.Colors.accent)

            // Every network shows its identity chip; mainnet additionally spells out the real-money
            // risk here, where the choice is made.
            NetworkBadge(network: network)
            if network.isMainnet {
                Text("Real bitcoin. Transactions are irreversible — only create this to hold real funds.",
                     bundle: .module, comment: "mainnet wallet creation warning")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
    }
}
