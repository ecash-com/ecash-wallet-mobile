// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The wallet manager, presented as a sheet from the Home switcher pill. One row per wallet
/// (avatar, label, network, backup state, selected check); tap to switch. Per-row "more" →
/// rename / remove (remove warns extra-loudly when the wallet isn't backed up — Golden Rule §5
/// purge). "New" and "Import" reuse the existing Create/Import flows via navigation.
///
/// Dismissal: any change of the selected wallet (switch, create, import) closes the sheet —
/// Home re-roots to the new wallet.
struct WalletManagerSheet: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss
    // Not `private` — Fuse bridges @State to Compose (skip-fuse rule).
    @State var renameTarget: ManagedWallet? = nil
    @State var renameText = ""
    @State var removeTarget: ManagedWallet? = nil
    @State var path: [WalletManagerRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Wallets") {
                    ForEach(app.wallets) { wallet in
                        walletRow(wallet)
                    }
                }
                Section {
                    Button { path.append(.create) } label: {
                        actionRowLabel(icon: Icon.add, title: "New wallet")
                    }
                    Button { path.append(.importWallet) } label: {
                        actionRowLabel(icon: Icon.importWallet, title: "Import wallet")
                    }
                }
            }
            .groupedListStyle()
            .navigationTitle("Wallets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { dismiss() } label: { Text("Done") }
                }
            }
            .navigationDestination(for: WalletManagerRoute.self) { route in
                switch route {
                case .create:
                    CreateConfirmView(viewModel: app.makeCreateViewModel(),
                                      defaultName: app.nextDefaultWalletName)
                case .importWallet:
                    ImportWalletView(viewModel: app.makeImportViewModel(),
                                     defaultName: app.nextDefaultWalletName)
                }
            }
        }
        // Switching/creating/importing changes the selection — close and let Home re-root.
        .onChange(of: app.selectedWalletId) { _, _ in dismiss() }
        // Rename: small sheet with a text field.
        .sheet(item: $renameTarget) { wallet in
            renameSheet(wallet)
        }
        // Remove: explicit confirmation, extra-loud when not backed up.
        .confirmationDialog(removeTitle,
                            isPresented: removeBinding,
                            titleVisibility: .visible) {
            Button("Remove wallet", role: .destructive) {
                if let wallet = removeTarget {
                    app.removeWallet(id: wallet.id)
                    removeTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: {
            Text(removeMessage)
        }
    }

    private func walletRow(_ wallet: ManagedWallet) -> some View {
        HStack(spacing: Theme.Space.x3) {
            Button {
                app.selectWallet(id: wallet.id)
            } label: {
                HStack(spacing: Theme.Space.x3) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.xs)
                            .fill(Theme.Colors.accent)
                        Text(String(wallet.label.prefix(1)).uppercased())
                            .font(.grotesk(14, .bold))
                            .foregroundStyle(Theme.Colors.accentText)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(wallet.label)
                            .textStyle(.body)
                            .foregroundStyle(Theme.Colors.text0)
                        Text(metaText(wallet))
                            .textStyle(.xs)
                            .foregroundStyle(wallet.isBackedUp ? Theme.Colors.text2 : Theme.Colors.warning)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if wallet.id == app.selectedWalletId {
                Image(icon: Icon.check)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.Colors.accent)
            }

            Button {
                renameText = wallet.label
                renameTarget = wallet
            } label: {
                Image(icon: Icon.rename)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .buttonStyle(.plain)

            Button {
                removeTarget = wallet
            } label: {
                Image(icon: Icon.remove)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .buttonStyle(.plain)
        }
    }

    private func metaText(_ wallet: ManagedWallet) -> String {
        let network = NetworkRegistry.params(for: wallet.network).displayName
        return wallet.isBackedUp ? network : "\(network) · Not backed up"
    }

    private func actionRowLabel(icon: String, title: String) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Image(icon: icon).resizable().scaledToFit().frame(width: 16, height: 16)
            Text(title).textStyle(.body)
        }
        .foregroundStyle(Theme.Colors.accent)
    }

    private func renameSheet(_ wallet: ManagedWallet) -> some View {
        NavigationStack {
            ZStack {
                Theme.Colors.bg0.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Theme.Space.x4) {
                    TextField("Wallet name", text: $renameText)
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text0)
                        .autocorrectionDisabled()
                        .padding(Theme.Space.x3)
                        .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    Text("Names are stored only on this device — they don't travel with the recovery phrase.")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                    WalletButton(title: "Save") {
                        app.renameWallet(id: wallet.id, to: renameText)
                        renameTarget = nil
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                    Spacer()
                }
                .padding(Theme.Space.gutter)
            }
            .navigationTitle("Rename wallet")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { renameTarget = nil } label: { Text("Cancel") }
                }
            }
        }
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })
    }

    private var removeTitle: String {
        "Remove \(removeTarget?.label ?? "wallet")?"
    }

    private var removeMessage: String {
        guard let wallet = removeTarget else { return "" }
        if wallet.isBackedUp {
            return "This deletes the wallet from this device. You can restore it later with its recovery phrase."
        }
        return "This wallet is NOT backed up. Removing it without the recovery phrase means its coins are lost forever."
    }
}

enum WalletManagerRoute: Hashable {
    case create
    case importWallet
}
