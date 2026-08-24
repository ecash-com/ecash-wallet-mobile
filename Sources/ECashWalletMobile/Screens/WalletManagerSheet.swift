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
    /// Presentation is its OWN state, deliberately not derived from `removeTarget` — see
    /// `confirmationDialog` below for why deriving it silently broke removal on Android.
    @State var isRemovingWallet = false
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
            .navigationTitle(Text("Wallets", bundle: .module, comment: "wallet manager title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ConfirmToolbarButton { dismiss() }
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
        // `isPresented` is a plain Bool, NOT a binding derived from `removeTarget`, because SkipUI
        // dismisses BEFORE it runs the button action (`Presentation.swift`):
        //
        //     ConfirmationDialogButton(action: { isPresented.set(false); button.action() })
        //
        // With a derived binding, that first call ran our setter, cleared `removeTarget`, and the
        // action then found nil and did nothing — the dialog closed and the wallet stayed. SwiftUI
        // runs the action first, so iOS worked and Android silently didn't. Keeping the payload in
        // its own state means dismissal order can't erase what we're about to act on.
        .confirmationDialog(removeTitle,
                            isPresented: $isRemovingWallet,
                            titleVisibility: .visible) {
            Button("Remove wallet", role: .destructive) {
                if let wallet = removeTarget { app.removeWallet(id: wallet.id) }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: {
            if removeTarget?.isBackedUp == true {
                Text("This deletes the wallet from this device. You can restore it later with its recovery phrase.",
                     bundle: .module, comment: "remove backed-up wallet warning")
            } else {
                Text("This wallet is NOT backed up. Removing it without the recovery phrase means its coins are lost forever.",
                     bundle: .module, comment: "remove not-backed-up wallet warning")
            }
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
                        // Balance in each wallet's OWN unit — a Bitcoin wallet and an eCash wallet
                        // can sit next to each other here, and "BTC" on the wrong row would be a
                        // small lie about which chain the coins are on.
                        WalletBalanceLabel(balance: app.balanceSummary(walletId: wallet.id),
                                           unitLabel: NetworkRegistry.params(for: wallet.network).unitLabel)
                        Text(metaText(wallet), bundle: .module)
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
                isRemovingWallet = true
            } label: {
                Image(icon: Icon.remove)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .buttonStyle(.plain)
        }
    }

    // LocalizedStringKey rendered via Text(_, bundle:) — Fuse-compatible. Backed-up rows just show
    // the network name; the not-backed-up suffix localizes. (%@ is the network name.)
    private func metaText(_ wallet: ManagedWallet) -> LocalizedStringKey {
        let network = NetworkRegistry.params(for: wallet.network).displayName
        return wallet.isBackedUp ? "\(network)" : "\(network) · Not backed up"
    }

    private func actionRowLabel(icon: Icon, title: LocalizedStringKey) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Image(icon: icon).resizable().scaledToFit().frame(width: 16, height: 16)
            Text(title, bundle: .module).textStyle(.body)
        }
        .foregroundStyle(Theme.Colors.accent)
    }

    private func renameSheet(_ wallet: ManagedWallet) -> some View {
        NavigationStack {
            ZStack {
                Theme.Colors.bg0.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Theme.Space.x4) {
                    TextField("Wallet name", text: $renameText)
                        .textFieldStyle(.plain)
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text0)
                        .autocorrectionDisabled()
                        .fieldBoxInset()
                        .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    Text("Names are stored only on this device — they don't travel with the recovery phrase.",
                         bundle: .module, comment: "rename wallet explainer")
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
            .navigationTitle(Text("Rename wallet", bundle: .module, comment: "rename wallet sheet title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    CloseToolbarButton { renameTarget = nil }
                }
            }
        }
    }

    // LocalizedStringKey for the confirmationDialog title (%@ is the wallet name).
    private var removeTitle: LocalizedStringKey {
        "Remove \(removeTarget?.label ?? "wallet")?"
    }
}

enum WalletManagerRoute: Hashable {
    case create
    case importWallet
}
