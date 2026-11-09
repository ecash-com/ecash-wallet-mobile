// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Switch the network a wallet is viewed on (`docs/seed-container-model.md §3.1`, nested):
/// the mainchains the wallet can live on, and under the one it's on, that chain's sidechains it
/// has an account on. One tap switches — explicit, never a swipe or a segmented control, because a
/// network change is a money-surface change (Golden Rule §6/§8): the chip, unit, explorer and the
/// send review all follow it. The current network is marked and tapping it does nothing.
///
/// Switching to a network the wallet has no account on yet derives one, which reads the phrase
/// once — `AppState.switchNetwork` gates that behind device auth when app-lock is on.
struct NetworkSwitcherSheet: View {
    let walletId: String
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss
    @State var isSwitching = false   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var errorMessage: String? = nil

    var body: some View {
        let wallet = app.wallets.first { $0.id == walletId }
        let current = wallet?.network
        let mainchains = app.availableMainchains(for: walletId)
        let sidechains = app.availableSidechains(for: walletId)
        NavigationStack {
            List {
                if let wallet {
                    Section {
                        Text(verbatim: wallet.label)
                            .textStyle(.sm)
                            .foregroundStyle(Theme.Colors.text1)
                            .listRowBackground(Color.clear)
                    }
                }
                Section(header: Text("Network", bundle: .module, comment: "network switcher: mainchains header")) {
                    ForEach(mainchains, id: \.self) { network in
                        row(network, isCurrent: network == current, nested: false)
                        // Sidechains nest under the mainchain they settle to — the one being viewed.
                        if network == current?.parentChain ?? current {
                            ForEach(sidechains, id: \.self) { sidechain in
                                row(sidechain, isCurrent: sidechain == current, nested: true)
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .textStyle(.sm)
                            .foregroundStyle(Theme.Colors.negative)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.bg0)
            .navigationTitle(Text("Switch network", bundle: .module, comment: "network switcher title"))
            .toolbar { CloseToolbarButton { dismiss() } }
        }
    }

    private func row(_ network: WalletNetwork, isCurrent: Bool, nested: Bool) -> some View {
        Button {
            guard !isCurrent, !isSwitching else { return }
            isSwitching = true
            errorMessage = nil
            Task {
                let ok = await app.switchNetwork(walletId: walletId, to: network)
                isSwitching = false
                if ok {
                    dismiss()
                } else {
                    errorMessage = app.networkSwitchMessage
                }
            }
        } label: {
            HStack(spacing: Theme.Space.x3) {
                if nested {
                    Image(icon: Icon.disclosure)
                        .foregroundStyle(Theme.Colors.text2)
                }
                NetworkBadge(network: network)
                Text(verbatim: NetworkRegistry.params(for: network).displayName)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                Spacer()
                // No glyph for "no account here yet" (a lock read as unavailable — Jake,
                // 2026-11-09): the device-auth prompt on first open says what it needs itself.
                if isCurrent {
                    Image(icon: Icon.check)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(.leading, nested ? Theme.Space.x4 : 0)
            .padding(.vertical, Theme.Space.x1)
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .listRowBackground(Color.clear)
    }
}
