// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Asks which wallet should pay an incoming payment link, when more than one could.
///
/// Only shown when there's a real choice — one candidate is handled without a prompt. The network
/// chip on every row is the safety mechanism (Golden Rule §6): for a link that didn't name a chain,
/// a `bc1…` address is valid on Bitcoin AND eCash, and only the user knows which one the payee is
/// actually watching. Choosing wrong sends real value somewhere it will never be seen.
struct PaymentLinkWalletPicker: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.paymentLinkChoices) { wallet in
                        Button { app.choosePaymentLinkWallet(id: wallet.id); dismiss() } label: {
                            HStack(spacing: Theme.Space.x3) {
                                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                                    Text(wallet.label)
                                        .textStyle(.body)
                                        .foregroundStyle(Theme.Colors.text0)
                                    WalletBalanceLabel(balance: app.balanceSummary(walletId: wallet.id),
                                                       unitLabel: NetworkRegistry.params(for: wallet.network).unitLabel)
                                }
                                Spacer(minLength: Theme.Space.x2)
                                NetworkBadge(network: wallet.network)
                            }
                        }
                    }
                } header: {
                    Text("Pay from", bundle: .module, comment: "payment link: choose a wallet")
                } footer: {
                    // Says outright that the link didn't specify a chain — the user can't infer it
                    // from the address, because the two chains share an address format.
                    if app.paymentLinkIsAmbiguous {
                        Text("This link doesn't say which chain it's for. The address is valid on both Bitcoin and eCash — pick the one the recipient is expecting.",
                             bundle: .module, comment: "payment link: chain not specified warning")
                    } else {
                        Text("More than one of your wallets can pay this request.",
                             bundle: .module, comment: "payment link: multiple candidates")
                    }
                }
            }
            .groupedListStyle()
            .navigationTitle(Text("Choose a wallet", bundle: .module, comment: "payment link picker title"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseToolbarButton { app.clearPaymentLinkChoice(); dismiss() }
                }
            }
        }
    }
}
