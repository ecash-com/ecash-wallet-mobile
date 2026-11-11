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
    /// BIP21 body from an incoming payment link, handed to the Send flow as its starting address.
    @State var prefilledSendLink: String? = nil
    /// Set when Send is opened from the claim nudge, so it starts on the destination picker with
    /// the full balance selected.
    @State var sweepPrefill = false
    @State var claimSweepDismissed = false
    @State var showBackup = false
    @State var showWalletManager = false
    @State var showNetworkSwitcher = false   // the Home chip's sheet
    @State var showFaucet = false
    @State var showSplit = false           // "Split coins" sheet
    @State var splitDismissed = false      // per-session: dismiss the split nudge without splitting
    @State var showSidechains = false      // Sidechains sheet (networks with a BIP300 enforcer only)
    @State var showWithdraw = false        // Withdraw options sheet (sidechain wallets only)
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
                .refreshable { await app.sync(force: true) }
            } else {
                PlaceholderScreen(heading: "Your wallet",
                                  note: "No wallet selected.")
            }
        }
        // Sync the selected wallet against its backend when Home appears (cached balance shows first).
        .task {
            // Drain the bridge (Android cold start), THEN consume anything already pending.
            // `.onChange` alone can't cover this: on Android the link is handled during RootView's
            // .onAppear, so `pendingPaymentLink` is already set before Home mounts, and onChange
            // only fires on a SUBSEQUENT change — never the initial value. iOS didn't show it
            // because there the URL arrives after the UI is up, which is a genuine change.
            app.recheckPaymentLinkAfterLaunch()
            openSendForPendingLinkIfAny()
            await app.sync()
        }
        // A payment link arrived from outside the app — open Send prefilled with it. Deliberately
        // stops at the recipient step: the link is untrusted input, so the user still confirms
        // recipient, amount, fee and network before anything is broadcast (Golden Rule §7).
        .onChange(of: app.pendingPaymentLink) { _, _ in openSendForPendingLinkIfAny() }
        // Which wallet should pay? Only presented when more than one can — see AppState.
        .sheet(isPresented: Binding(
            get: { !app.paymentLinkChoices.isEmpty },
            set: { if !$0 { app.clearPaymentLinkChoice() } })) {
            PaymentLinkWalletPicker()
        }
        .alert("Can't open that link", isPresented: Binding(
            get: { app.paymentLinkProblem != nil },
            set: { if !$0 { app.clearPaymentLinkProblem() } })) {
            Button("OK", role: .cancel) { app.clearPaymentLinkProblem() }
        } message: {
            Text(verbatim: app.paymentLinkProblem ?? "")
        }
        // Receive is a modal sheet (grab-an-address-and-dismiss), not a navigation push.
        .sheet(isPresented: $showReceive) { ReceiveScreen() }
        // Send is a full-screen cover — a focused, multi-step money flow, not a peek-and-dismiss.
        .fullScreenFlow(isPresented: $showSend) {
            if let vm = app.makeSendViewModel() {
                SendScreen(viewModel: vm)
                    .id(sendToken)
                    .onAppear {
                        // Prefill from an incoming payment link. Set here rather than at
                        // construction because `makeSendViewModel` caches an in-flight VM; this
                        // fills the recipient field and leaves every confirmation step intact.
                        if let link = prefilledSendLink {
                            vm.addressText = link
                            prefilledSendLink = nil
                        }
                        // From the claim nudge: preselect the whole balance so "move it all" is
                        // the default rather than something the user has to know to ask for. It's
                        // a true BDK drain (no change, exact fee deducted), which is what empties
                        // a single-key wallet cleanly. The user still picks the destination and
                        // confirms — Max is a starting amount, not a decision made for them.
                        if sweepPrefill {
                            vm.tapMax()
                            sweepPrefill = false
                        }
                    }
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
        .sheet(isPresented: $showNetworkSwitcher) {
            if let id = app.selectedWalletId { NetworkSwitcherSheet(walletId: id) }
        }
        // Signet faucet: request valueless test coins (signet-only; the button is gated too).
        .sheet(isPresented: $showFaucet) {
            if let vm = app.makeFaucetViewModel() {
                FaucetSheet(viewModel: vm)
            }
        }
        // Transaction detail for a tapped activity row.
        .sheet(item: $detailTx) { tx in
            if let wallet = app.selectedWallet {
                TxDetailSheet(tx: tx, unitLabel: app.unitLabel, network: wallet.network,
                              wallet: wallet,
                              sidechainName: app.sidechainName(for: tx),
                              loadWithdrawalStatus: { await app.withdrawalStatus(for: tx) })
            }
        }
        // Withdraw: a sidechain wallet's way back to its mainchain (regular / fast chooser first).
        .sheet(isPresented: $showWithdraw) { WithdrawOptionsSheet() }
        // Sidechains: read-only browse of this network's BIP300 sidechains.
        .sheet(isPresented: $showSidechains) {
            if let vm = app.makeSidechainsViewModel() {
                SidechainsScreen(viewModel: vm)
            }
        }
        // Split coins: separate eCash from Bitcoin (a self-drain to a fresh address).
        .sheet(isPresented: $showSplit) {
            if let vm = app.makeSplitViewModel() {
                SplitCoinsView(viewModel: vm)
            }
        }
    }

    /// eCash-only nudge shown when a Bitcoin check found coins still live on Bitcoin (shared). Tapping
    /// opens the split flow; the ✕ dismisses it for this session (it also clears itself once split,
    /// since the summary recomputes `needsSplitCount == 0`).
    /// Open Send prefilled from an incoming payment link, if one is waiting. Called from BOTH
    /// `.task` and `.onChange` — see the note in `.task` for why either alone misses a case.
    private func openSendForPendingLinkIfAny() {
        guard let body = app.takePendingPaymentLink() else { return }
        app.beginSendFlow()
        prefilledSendLink = body
        sendToken += 1
        showSend = true
    }

    private var splitNudge: some View {
        HStack(alignment: .top, spacing: Theme.Space.x2) {
            Button {
                showSplit = true
            } label: {
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text("Separate your eCash from your Bitcoin", bundle: .module, comment: "home split nudge title")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text0)
                    Text("You hold coins that exist on both chains. Split them so spending your eCash can't move your Bitcoin. Tap to split.",
                         bundle: .module, comment: "home split nudge body")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button { splitDismissed = true } label: {
                Image(icon: Icon.close).resizable().scaledToFit().frame(width: 14, height: 14)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.x4)
        .background(Theme.Colors.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.accent.opacity(0.4), lineWidth: 1))
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
                // The chip is the network switcher (docs/seed-container-model.md §4): it opens a sheet
                // with the current network marked; nothing changes until a row is tapped there.
                Button { showNetworkSwitcher = true } label: {
                    HStack(spacing: Theme.Space.x1) {
                        NetworkBadge(network: wallet.network)
                        Image(icon: Icon.expand)
                            .foregroundStyle(Theme.Colors.text2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Switch network", bundle: .module, comment: "home: network chip opens the switcher"))

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
                // Not yet spendable, shown so it doesn't look lost. Our own change (Thunder: a send's
                // change waits for the next block) is told apart from incoming payments, so a send
                // doesn't look like the rest of the balance left.
                if !app.balanceHidden, app.pendingBalance.sats > 0 {
                    let change = app.pendingChange
                    let incoming = Amount(sats: app.pendingBalance.sats - change.sats)
                    if incoming.sats > 0 {
                        Text("+\(incoming.formattedCoin()) \(params.unitLabel) pending",
                             bundle: .module, comment: "incoming unconfirmed balance, not yet spendable; %@ are amount + unit")
                            .textStyle(.xs)
                            .foregroundStyle(Theme.Colors.warning)
                    }
                    if change.sats > 0 {
                        Text("+\(change.formattedCoin()) \(params.unitLabel) change · usable after the next block",
                             bundle: .module, comment: "own change from a send, spendable once the next block confirms it; %@ are amount + unit")
                            .textStyle(.xs)
                            .foregroundStyle(Theme.Colors.text2)
                            .multilineTextAlignment(.center)
                    }
                }
                // Spendable, but not settled: incoming payments whose senders can still replace
                // them (unconfirmed coins became spendable 2026-11-11; Send warns when a payment
                // depends on one). Shown so the user knows which part of the balance that is.
                if !app.balanceHidden, app.unconfirmedBalance.sats > 0 {
                    Text("\(app.unconfirmedBalance.formattedCoin()) \(params.unitLabel) of this is unconfirmed",
                         bundle: .module, comment: "home: share of the balance that is incoming payments not yet confirmed; %@ are amount + unit")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.warning)
                }
                syncStatus
            }
            .padding(.vertical, Theme.Space.x5)

            actionButtons

            if !wallet.isBackedUp {
                backupNudge
            }

            // Retired-network nudge: this wallet is open on alphanet / betanet / Thunder betanet.
            // The same seed opens on eCash in one tap (deriving the account if it has none — the
            // switch path handles the device-auth gate), which beats merely hiding the wallet.
            if app.selectedWalletIsOnRetiredNetwork {
                retiredNetworkNudge(wallet: wallet, networkName: params.displayName)
            }

            // Claimed-key nudge: a single-key (WIF) wallet holding funds. Gated on keyType rather
            // than the "ECX Claim" label so renaming the wallet can't hide it, and so a key
            // imported the long way (Advanced → Private key) gets the same offer.
            if claimSweepAvailable, !claimSweepDismissed {
                claimSweepNudge
            }

            // Split-coins nudge: eCash wallet holding coins a Bitcoin check found still shared.
            if let s = app.splitSummary, s.needsSplitCount > 0, !splitDismissed {
                splitNudge
            }

            // Sidechains: only where this network has a BIP300 enforcer (betanet today).
            if app.sidechainsAvailable {
                sidechainsRow(networkName: params.displayName)
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
                              fiatText: app.fiatString(forSats: abs(tx.netSats)),
                              amountHidden: app.balanceHidden,
                              sidechainName: app.sidechainName(for: tx))
                            .padding(.vertical, Theme.Space.x2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.x2)
        }
    }

    /// The action row: Receive, and Send prominent. On a SIDECHAIN wallet Withdraw leads — the only
    /// way its coins get back to the mainchain. Equal-width buttons that fill the row, so two or three
    /// read as deliberate (spaced circles left a gappy row once there were only two).
    ///
    /// No "Buy"/"Swap" placeholders, even disabled: App Review read them as cryptocurrency exchange
    /// services (Guideline 3.1.5(iii)) and asked for exchange licences. Add them only with a
    /// licensed partner behind them.
    ///
    /// **Large text.** With the font or display size turned up, three icon+label buttons don't fit
    /// and a label truncates ("Withdra"). The row is offered at a ladder of label sizes and
    /// `ViewThatFits` takes the first that fits, so every button always shares ONE size — a
    /// per-label `minimumScaleFactor` would shrink "Withdraw" more than "Send". Measured by the
    /// platform, so it holds in every language (no character-count maths).
    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(labelSize: 16)
            actionRow(labelSize: 14)
            actionRow(labelSize: 13)
            actionRow(labelSize: 12)
            actionRow(labelSize: 11)
            // Last resort (largest font + display size): drop the icons so the words get the room.
            actionRow(labelSize: 13, showsIcons: false)
            actionRow(labelSize: 11, showsIcons: false)
            actionRow(labelSize: 10, showsIcons: false)
        }
    }

    /// The titles in this row, in order. Every button sizes itself to the WIDEST of them (see
    /// `actionButton`), so the row's natural width is what the widest label needs in each button.
    private var actionTitles: [LocalizedStringKey] {
        isSidechainWallet ? ["Withdraw", "Receive", "Send"] : ["Receive", "Send"]
    }

    private func actionRow(labelSize: CGFloat, showsIcons: Bool = true) -> some View {
        HStack(spacing: Theme.Space.x3) {
            if isSidechainWallet {
                actionButton(icon: Icon.sidechains, title: "Withdraw", prominent: false, labelSize: labelSize, showsIcon: showsIcons) {
                    showWithdraw = true
                }
            }
            actionButton(icon: Icon.receive, title: "Receive", prominent: false, labelSize: labelSize, showsIcon: showsIcons) {
                showReceive = true
            }
            actionButton(icon: Icon.send, title: "Send", prominent: true, labelSize: labelSize, showsIcon: showsIcons) {
                app.beginSendFlow()   // drop any cached (finished) Send VM → fresh flow
                sendToken += 1        // force a fresh SendScreen (new nav path) (see sendToken)
                showSend = true
            }
        }
    }

    private var isSidechainWallet: Bool {
        guard let network = app.selectedWallet?.network else { return false }
        return SidechainWalletNetwork.mainchain(ofSidechainWallet: network) != nil
    }

    /// One action: icon + label in a full-width rounded button. Send (prominent) is accent-filled;
    /// the rest are the bordered secondary look shared with Receive's Copy/Share. Each wrapper takes
    /// `maxWidth: .infinity` so the row splits evenly (same reason as Receive's action row).
    ///
    /// Invisible, zero-height copies of every title in the row sit above the label, so each button's
    /// natural width is the widest title's. That's what lets `ViewThatFits` judge the row correctly: the buttons split
    /// the row evenly, so the widest label must fit in its share, not merely the sum of the labels.
    private func actionButton(icon: Icon, title: LocalizedStringKey, prominent: Bool, labelSize: CGFloat,
                              showsIcon: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Zero-height, invisible copies of every title, laid out like the real label: they
                // set the width without moving this button's own icon away from its text.
                ForEach(Array(actionTitles.enumerated()), id: \.offset) { _, widest in
                    HStack(spacing: Theme.Space.x2) {
                        if showsIcon { Color.clear.frame(width: 16, height: 0) }
                        Text(widest, bundle: .module).font(.jbMono(labelSize, .semibold)).lineLimit(1)
                            .frame(height: 0)
                    }
                    .opacity(0)
                    .accessibilityHidden(true)
                }
                HStack(spacing: Theme.Space.x2) {
                    if showsIcon {
                        Image(icon: icon).resizable().scaledToFit().frame(width: 16, height: 16)
                    }
                    Text(title, bundle: .module).font(.jbMono(labelSize, .semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(prominent ? Theme.Colors.accentText : Theme.Colors.text0)
            .padding(.horizontal, Theme.Space.x2)   // part of the measured width: labels never touch the edge
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.x3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(prominent ? Theme.Colors.accent : Theme.Colors.bg2))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(prominent ? Color.clear : Theme.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
                    Task { await app.sync(force: true) }
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
    /// A claimed key is a single address whose private key existed on paper before it reached this
    /// device — and, for an investor letter, possibly passed through other hands. Moving the funds
    /// into a wallet whose seed only ever existed here is the point of claiming, so offer it
    /// directly instead of leaving the user to work out Send → Max → pick a wallet.
    ///
    /// Shown only when there's somewhere to sweep TO and something to move; an investor with a
    /// single wallet sees nothing until they create one.
    private var claimSweepAvailable: Bool {
        guard let wallet = app.selectedWallet, wallet.keyType == .wif else { return false }
        guard app.balance.sats > 0 else { return false }
        return app.wallets.contains { $0.network == wallet.network && $0.id != wallet.id }
    }

    private var claimSweepNudge: some View {
        Button {
            app.beginSendFlow()
            sweepPrefill = true
            sendToken += 1
            showSend = true
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                Text("Move your ECX to another wallet", bundle: .module,
                     comment: "home claim sweep nudge title")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)
                Text("This key came from your letter, so it may exist elsewhere. Send the full balance to one of your own wallets to hold it securely.",
                     bundle: .module, comment: "home claim sweep nudge body")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Entry to the Sidechains sheet. A neutral card, not a nudge: nothing here needs doing, it's a
    /// place to go.
    private func sidechainsRow(networkName: String) -> some View {
        Button {
            showSidechains = true
        } label: {
            HStack(spacing: Theme.Space.x3) {
                Image(icon: Icon.sidechains)
                    .resizable().scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Theme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sidechains", bundle: .module, comment: "home row → sidechains screen")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text0)
                    Text("Explore the sidechains on \(networkName)", bundle: .module,
                         comment: "home sidechains row subtitle; %@ is the network name")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(icon: Icon.disclosure)
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func retiredNetworkNudge(wallet: ManagedWallet, networkName: String) -> some View {
        Button {
            Task { _ = await app.switchNetwork(walletId: wallet.id, to: WalletNetwork.currentEcash) }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                Text("This wallet is on a retired network", bundle: .module, comment: "home retired-network nudge title")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)
                Text("\(networkName) was a test network before the eCash fork. Tap to open this wallet on eCash.",
                     bundle: .module, comment: "home retired-network nudge body")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

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
