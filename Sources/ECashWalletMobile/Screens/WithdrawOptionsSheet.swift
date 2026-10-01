// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// What "Withdraw" opens on a sidechain wallet: the two ways to move coins back to the mainchain, each
/// explained before the user picks — the slow, trustless regular withdrawal, and the fast withdrawal
/// through a liquidity provider. Only the regular one exists today; fast is shown, honestly labelled,
/// so users know it's coming and why they might want it.
///
/// Fast withdrawal: BitWindow's runs through L2L's `fw1/fw2.drivechain.info` servers — the user pays
/// on the sidechain first and the provider pays out on the mainchain (custodial for that window). Those
/// servers don't serve betanet today, so there is nothing to connect it to yet.
struct WithdrawOptionsSheet: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss   // not `private` — Fuse bridges view properties
    @State var path: [WithdrawRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.x4) {
                    Text("Move coins back to \(mainchainName).", bundle: .module,
                         comment: "withdraw options intro; %@ is the mainchain name")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text1)

                    option(icon: Icon.pending,
                           title: Text("Regular withdrawal", bundle: .module, comment: "withdraw option title"),
                           body: Text("Miners approve it through the chain itself. No middleman and only network fees, but it takes months — about 3 at best.",
                                      bundle: .module, comment: "regular withdrawal explanation"),
                           badge: nil, enabled: true) {
                        path.append(.regular)
                    }

                    option(icon: Icon.send,
                           title: Text("Fast withdrawal", bundle: .module, comment: "withdraw option title"),
                           body: Text("A liquidity provider pays you on \(mainchainName) right away and takes your coins in return, for a small fee. You rely on the provider.",
                                      bundle: .module, comment: "fast withdrawal explanation; %@ is the mainchain name"),
                           badge: Text("Coming soon", bundle: .module, comment: "fast withdrawal unavailable badge"),
                           enabled: false) {}
                }
                .padding(Theme.Space.gutter)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.bg0)
            .navigationTitle(Text("Withdraw", bundle: .module, comment: "withdraw options sheet title"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CloseToolbarButton { dismiss() } }
            }
            .navigationDestination(for: WithdrawRoute.self) { route in
                switch route {
                case .regular:
                    if let vm = app.makeSidechainWithdrawViewModel() {
                        SidechainWithdrawScreen(viewModel: vm) { dismiss() }
                    }
                }
            }
        }
    }

    private var mainchainName: String {
        guard let network = app.selectedWallet?.network,
              let mainchain = SidechainWalletNetwork.mainchain(ofSidechainWallet: network) else { return "" }
        return NetworkRegistry.params(for: mainchain).displayName
    }

    private func option(icon: Icon, title: Text, body: Text, badge: Text?, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.x3) {
                Image(icon: icon)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(enabled ? Theme.Colors.accent : Theme.Colors.text2)
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    HStack(spacing: Theme.Space.x2) {
                        title.textStyle(.h3).foregroundStyle(Theme.Colors.text0)
                        if let badge {
                            badge.textStyle(.xs)
                                .foregroundStyle(Theme.Colors.text1)
                                .padding(.horizontal, Theme.Space.x2)
                                .padding(.vertical, 2)
                                .background(Theme.Colors.bg2, in: Capsule())
                        }
                    }
                    body.textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text1)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if enabled {
                    Image(icon: Icon.disclosure)
                        .resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(Theme.Colors.text2)
                }
            }
            .padding(Theme.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
    }
}

enum WithdrawRoute: Hashable {
    case regular
}
