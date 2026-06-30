// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The selected wallet's home: identity (label + network badge), live balance with sync state,
/// and the "not backed up" nudge. Syncs on appear and on manual refresh. Receive / Send arrive next.
struct WalletHomeScreen: View {
    @Environment(AppState.self) var app
    @State var showReceive = false   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var showSend = false
    // Bumped each time Send opens so the cover gets a FRESH SendScreen (new view model + nav path).
    // On Android SkipUI keeps a `fullScreenCover`'s view + @State alive across dismiss/re-present, so
    // without a changing `.id` the next Send reopened on the previous flow's "Sent" step with stale
    // data (iOS recreates the cover, so it was Android-only). See SendScreen `.id(sendToken)`.
    @State var sendToken = 0
    @State var showBackup = false
    @State var showWalletManager = false
    @State var showFaucet = false
    @State var detailTx: WalletTx? = nil

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            if let wallet = app.selectedWallet {
                // Scrollable: balance + actions + activity rows can exceed the screen, and a fixed
                // (non-scrolling) VStack with flexible children overflowed into an infinite Compose
                // layout recursion on Android.
                ScrollView {
                    content(for: wallet)
                }
                .scrollIndicators(.hidden)
                .refreshable { await app.sync() }
            } else {
                PlaceholderScreen(heading: "Your wallet",
                                  note: "No wallet selected.")
            }
        }
        // Sync the selected wallet against its backend when Home appears (cached balance shows first).
        .task { await app.sync() }
        // Receive is a modal sheet (grab-an-address-and-dismiss), not a navigation push.
        .sheet(isPresented: $showReceive) { ReceiveScreen() }
        // Send is a full-screen cover — a focused, multi-step money flow, not a peek-and-dismiss.
        .fullScreenFlow(isPresented: $showSend) {
            if let vm = app.makeSendViewModel() {
                SendScreen(viewModel: vm).id(sendToken)
            }
        }
        // Backup: gate → reveal → verify; clears the warning below on success.
        .fullScreenFlow(isPresented: $showBackup) {
            if let vm = app.makeBackupViewModel() {
                BackupFlowView(viewModel: vm)
            }
        }
        // Wallet manager: switch / rename / add / import / remove.
        .sheet(isPresented: $showWalletManager) { WalletManagerSheet() }
        // Signet faucet: request valueless test coins (signet-only; the button is gated too).
        .sheet(isPresented: $showFaucet) {
            if let vm = app.makeFaucetViewModel() {
                FaucetSheet(viewModel: vm)
            }
        }
        // Transaction detail for a tapped activity row.
        .sheet(item: $detailTx) { tx in
            if let wallet = app.selectedWallet {
                TxDetailSheet(tx: tx, unitLabel: app.unitLabel, network: wallet.network)
            }
        }
    }

    @ViewBuilder
    private func content(for wallet: ManagedWallet) -> some View {
        let params = NetworkRegistry.params(for: wallet.network)
        VStack(spacing: Theme.Space.x6) {
            // Header: the wallet switcher pill (leading) + the faucet "Get coins" pill (trailing,
            // signet-only via `app.faucetAvailable`).
            HStack {
                WalletSwitcherPill(label: wallet.label) { showWalletManager = true }
                Spacer()
                if app.faucetAvailable {
                    FaucetButton { showFaucet = true }
                }
            }

            VStack(spacing: Theme.Space.x2) {
                NetworkBadge(network: wallet.network)

                // Live balance with the privacy eye. JetBrains Mono is fixed-width already.
                HStack(spacing: Theme.Space.x2) {
                    Text(app.balanceHidden ? "••••••••" : app.balance.formattedCoin())
                        .font(.jbMono(36, .medium))
                        .foregroundStyle(Theme.Colors.text0)
                    Text(params.unitLabel)
                        .font(.jbMono(14, .medium))
                        .foregroundStyle(Theme.Colors.text2)
                    Button {
                        app.balanceHidden.toggle()
                    } label: {
                        Image(icon: app.balanceHidden ? Icon.hide : Icon.reveal)
                            .resizable().scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(Theme.Colors.text2)
                    }
                    .buttonStyle(.plain)
                }
                // Fiat equivalent — only for networks with a bundled price provider (e.g. mainnet).
                if !app.balanceHidden, let fiat = app.fiatString(forSats: app.balance.sats) {
                    Text(verbatim: "≈ \(fiat)")
                        .font(.jbMono(14, .regular))
                        .foregroundStyle(Theme.Colors.text2)
                }
                // Incoming unconfirmed (0-conf) — not yet spendable; shown so it doesn't look lost.
                if !app.balanceHidden, app.pendingBalance.sats > 0 {
                    Text("+\(app.pendingBalance.formattedCoin()) \(params.unitLabel) pending",
                         bundle: .module, comment: "incoming unconfirmed balance, not yet spendable; %@ are amount + unit")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.warning)
                }
                syncStatus
            }
            .padding(.vertical, Theme.Space.x5)

            actionCircles

            if !wallet.isBackedUp {
                backupNudge
            }

            recentActivity
        }
        .padding(Theme.Space.gutter)
        .padding(.top, Theme.Space.x2)
    }

    /// Recent-activity preview — the latest few transactions; the full history lives on the
    /// Activity tab. Empty wallets get a quiet hint. Layout discipline (Android Compose): boring
    /// `TxRow`s in a plain VStack, ONE section-level `maxWidth` frame (same pattern as
    /// `backupNudge`, proven stable) — no `Spacer`, no per-row flexible children. "See all" is
    /// intentionally absent: `MainTabView` owns its tab selection locally, so a programmatic jump
    /// to the Activity tab needs a verified construct first.
    @ViewBuilder
    private var recentActivity: some View {
        if app.transactions.isEmpty {
            Text("No transactions yet", bundle: .module, comment: "home empty activity")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
                .padding(.top, Theme.Space.x4)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.x3) {
                Text("Recent activity", bundle: .module, comment: "home activity section header")
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
                ForEach(app.recentTransactions) { tx in
                    Button {
                        detailTx = tx
                    } label: {
                        TxRow(tx: tx, unitLabel: app.unitLabel,
                              fiatText: app.fiatString(forSats: abs(tx.netSats)))
                            .padding(.vertical, Theme.Space.x2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.x2)
        }
    }

    /// The four-circle action row (mock): Send prominent, Receive live, Swap/Buy disabled
    /// ghosts until those features exist (out of v1 scope, §1).
    private var actionCircles: some View {
        HStack(spacing: Theme.Space.x6) {
            actionCircle(icon: Icon.swap, title: "Swap", prominent: false, enabled: false) {}
            actionCircle(icon: Icon.buy, title: "Buy", prominent: false, enabled: false) {}
            actionCircle(icon: Icon.receive, title: "Receive", prominent: false, enabled: true) {
                showReceive = true
            }
            actionCircle(icon: Icon.send, title: "Send", prominent: true, enabled: true) {
                app.beginSendFlow()   // drop any cached (finished) Send VM → fresh flow
                sendToken += 1        // force a fresh SendScreen (new nav path) (see sendToken)
                showSend = true
            }
        }
    }

    private func actionCircle(icon: Icon, title: LocalizedStringKey, prominent: Bool, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.x2) {
                ZStack {
                    Circle().fill(prominent ? Theme.Colors.accent : Theme.Colors.bg2)
                    Image(icon: icon)
                        .resizable().scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(prominent ? Theme.Colors.accentText : Theme.Colors.text0)
                }
                .frame(width: 56, height: 56)
                Text(title, bundle: .module)
                    .textStyle(.xs)
                    .foregroundStyle(prominent ? Theme.Colors.text0 : Theme.Colors.text1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// Sync state under the balance: a spinner while syncing, a tappable error on failure, nothing
    /// when idle — pull-to-refresh is the manual sync gesture. The row reserves a CONSTANT height in
    /// every state (idle keeps the syncing row, just invisible), so the indicator popping in/out
    /// never shifts the balance/actions below it (iOS + Android). A `ZStack` lets the failure button
    /// grow wider than the syncing row without truncating, while idle/syncing keep the same size.
    private var syncStatus: some View {
        ZStack {
            HStack(spacing: Theme.Space.x2) {
                ProgressView()
                Text("Syncing…", bundle: .module, comment: "sync in progress")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .opacity(app.syncState == .syncing ? 1 : 0)   // present (reserves space) but invisible unless syncing

            if case .failed(let message) = app.syncState {
                Button {
                    Task { await app.sync() }
                } label: {
                    HStack(spacing: Theme.Space.x1) {
                        Image(icon: Icon.refresh).resizable().scaledToFit().frame(width: 14, height: 14)
                        Text(message).textStyle(.xs)
                    }
                    .foregroundStyle(Theme.Colors.negative)
                }
            }
        }
    }

    /// Persistent "not backed up" nudge (Golden Rule §7) — taps into the Backup flow; the
    /// `!wallet.isBackedUp` condition above removes it once the verify step succeeds.
    private var backupNudge: some View {
        Button {
            showBackup = true
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                Text("Back up your recovery phrase", bundle: .module, comment: "home backup nudge title")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)
                Text("It's the only way to restore this wallet if you lose the device. Tap to back up now.",
                     bundle: .module, comment: "home backup nudge body")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.warningTint, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.warning.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
