// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Pick one of the user's own wallets as the send destination, instead of pasting an address.
///
/// The motivating flow is moving a whole balance between two wallets on this device — importing a
/// legacy key and sweeping it into a fresh wallet, say — where the alternative is hand-copying a
/// `bc1…` string between two screens on a phone, which is exactly where people paste the wrong thing.
///
/// **Only same-network wallets appear here** (filtered in `AppState.makeSendViewModel`). That's a
/// safety property: eCash uses Bitcoin's `bc` HRP, so its addresses are indistinguishable from real
/// mainnet ones by eye — a cross-network row would look completely legitimate and send coins to a
/// chain that will never see them.
///
/// Picking fills the address field; it does not send anything. The user still sees the actual address
/// and still confirms it at review (Golden Rule §7).
struct SendDestinationPicker: View {
    let destinations: [SendViewModel.Destination]
    let networkDisplayName: String
    let unitLabel: String
    let onPick: (SendViewModel.Destination) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            // A List (not a ForEach in a VStack) on purpose: dynamic rows in a plain stack have
            // blown the Compose layout on Android before (the tx-list stack overflow).
            List {
                Section {
                    ForEach(destinations) { destination in
                        Button {
                            onPick(destination)
                            dismiss()
                        } label: {
                            row(destination)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("On \(networkDisplayName)", bundle: .module,
                         comment: "send destination picker section header; %@ is the network name")
                } footer: {
                    Text("Only your wallets on this network can be listed — an address from another network would look valid but the coins would be unspendable.",
                         bundle: .module, comment: "send destination picker: why other wallets aren't listed")
                }
            }
            .groupedListStyle()
            .navigationTitle(Text("My wallets", bundle: .module, comment: "send destination picker title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    CloseToolbarButton { dismiss() }
                }
            }
        }
    }

    private func row(_ destination: SendViewModel.Destination) -> some View {
        HStack(spacing: Theme.Space.x3) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.xs)
                    .fill(Theme.Colors.accent)
                Text(String(destination.label.prefix(1)).uppercased())
                    .font(.grotesk(14, .bold))
                    .foregroundStyle(Theme.Colors.accentText)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(destination.label)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                WalletBalanceLabel(balance: destination.balance, unitLabel: unitLabel)
            }

            Spacer()
        }
        .fullRowTapTarget()
    }
}
