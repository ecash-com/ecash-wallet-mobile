// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// "Copy to network" — adds a wallet on a network that shares its keys, from the same recovery
/// phrase, without retyping it (`docs/copy-wallet-to-network.md`). Pick → confirm
/// (device-auth) → the new wallet is selected and the sheet closes. Nothing is sent or moved.
struct CopyWalletView: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss
    @State var vm: CopyWalletViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)

    init(viewModel: CopyWalletViewModel) { _vm = State(initialValue: viewModel) }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.x4) {
                    Text("Copy to another network", bundle: .module, comment: "copy wallet heading")
                        .textStyle(.h1)
                        .foregroundStyle(Theme.Colors.text0)

                    Text("Adds \(vm.walletLabel) to another network using the same recovery phrase. It has the same keys and addresses, so it shows whatever this phrase holds there. Nothing is sent or moved.",
                         bundle: .module, comment: "copy wallet explainer; %@ is the wallet name")
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text1)

                    VStack(spacing: Theme.Space.x2) {
                        ForEach(vm.targets) { target in
                            targetRow(target)
                        }
                    }

                    if vm.selectedIsRealMoney {
                        Text("This network holds real money. Transactions are irreversible.",
                             bundle: .module, comment: "copy wallet: real-money target warning")
                            .textStyle(.xs)
                            .foregroundStyle(Theme.Colors.warning)
                    }

                    if let error = vm.errorMessage {
                        Text(error).textStyle(.sm).foregroundStyle(Theme.Colors.negative)
                    }

                    WalletButton(title: vm.isBusy ? "Copying…" : "Copy wallet") {
                        Task { await vm.confirm() }
                    }
                    .disabled(vm.selected == nil || vm.isBusy)
                    .opacity(vm.selected == nil || vm.isBusy ? 0.4 : 1)
                    .padding(.top, Theme.Space.x2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.gutter)
            }
        }
        // A successful copy selects the new wallet: the job is done, so close.
        .onChange(of: app.selectedWalletId) { _, _ in dismiss() }
    }

    private func targetRow(_ target: CopyWalletViewModel.Target) -> some View {
        let isSelected = vm.selected == target.network
        return Button { vm.choose(target) } label: {
            HStack(spacing: Theme.Space.x3) {
                NetworkBadge(network: target.network)
                Spacer()
                if target.isAdded {
                    // Already in the wallet list on this network — shown for completeness, not tappable.
                    Text("Added", bundle: .module, comment: "copy wallet: this network already has the wallet")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                    Image(icon: Icon.check)
                        .resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(Theme.Colors.text2)
                } else if isSelected {
                    Image(icon: Icon.check)
                        .resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(Theme.Space.x3)
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(isSelected ? Theme.Colors.accent : Theme.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy || target.isAdded)
        .opacity(target.isAdded ? 0.5 : 1)
    }
}
