// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Transaction detail, shown as a sheet when an activity row is tapped.
///
/// Layout: a centered hero (direction glyph, headline amount, a colored status pill, the date),
/// a grouped details card (amount / fee / total / confirmations / date / network / RBF), the txid
/// with copy, and a prominent full-width "View on block explorer" action (URL from
/// `NetworkRegistry`, Golden Rule §4). Everything is `Theme` tokens; layout stays Android-safe
/// (shallow stacks, hairline rectangles instead of `Divider`).
struct TxDetailSheet: View {
    let tx: WalletTx
    let unitLabel: String
    let network: WalletNetwork
    /// The owning wallet — turns `tx.ownKeys` into derivation paths. Optional so previews/sidechain
    /// callers can omit it; the derivation rows simply don't render.
    var wallet: ManagedWallet? = nil
    /// For a sidechain deposit: the sidechain's name, if known (`AppState.sidechainName(for:)`).
    var sidechainName: String? = nil
    /// For a withdrawal: looks up where it stands (`AppState.withdrawalStatus(for:)`). Called on appear.
    var loadWithdrawalStatus: (() async -> WithdrawalStatus?)? = nil
    @State var withdrawalStatus: WithdrawalStatus? = nil
    @State var withdrawalStatusLoaded = false
    @State var copied = false   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var detailsExpanded = false   // CoinNews txs: raw tx rows fold into a DisclosureGroup

    var body: some View {
        // No NavigationStack/toolbar and no close button: the sheet is swipe-down dismissible, and a
        // toolbar would render a Material top app bar on Android that tints grey on scroll. Just the
        // content, edge-to-edge on `bg0` — clean and identical on both platforms.
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.x5) {
                    if tx.isCoinNews {
                        coinNewsHero
                        detailsDisclosure   // raw tx rows hidden until tapped
                    } else {
                        hero
                        if let slot = tx.sidechainDepositSlot {
                            depositCard(slot: slot)
                        } else if tx.isSidechainWithdrawal {
                            withdrawalCard
                        }
                        detailsCard
                    }
                    txidCard
                    explorerButton
                }
                .padding(Theme.Space.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Hero

    /// Smallest-unit label for THIS network — "sat" on Bitcoin, "szat" on eCash.
    /// Never hardcode it: an eCash fee shown as "sat/vB" borrows Bitcoin's unit for
    /// another chain's money.
    private var subUnit: String { NetworkRegistry.params(for: network).subUnitLabel }

    private var hero: some View {
        VStack(spacing: Theme.Space.x3) {
            ZStack {
                Circle().fill(heroTint)
                Image(icon: heroIcon)
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(heroGlyph)
            }
            .frame(width: 64, height: 64)

            if let slot = tx.sidechainDepositSlot {
                SidechainDepositTitle(name: sidechainName, slot: slot, received: tx.isReceived)
                    .font(.satoshi(20, .semibold))
                    .foregroundStyle(Theme.Colors.text0)
            } else if tx.isSidechainWithdrawal {
                Text("Withdrawal to \(mainchainName)", bundle: .module,
                     comment: "tx detail title: sidechain → mainchain withdrawal; %@ is the mainchain name")
                    .font(.satoshi(20, .semibold))
                    .foregroundStyle(Theme.Colors.text0)
            }

            VStack(spacing: 2) {
                Text(verbatim: amountCoin)
                    .font(.jbMono(32, .medium))
                    .foregroundStyle(tx.isReceived ? Theme.Colors.positive : Theme.Colors.text0)
                    .lineLimit(1)
                Text(verbatim: unitLabel)
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
            }

            statusPill

            if let epoch = tx.timestampEpochSeconds {
                Text(verbatim: Self.fullDate(epoch))
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text2)
            }

            if tx.isBeforeFork {
                Text("Before the fork: confirmed before \(NetworkRegistry.params(for: network).displayName) forked from Bitcoin, so this transaction is on both chains.",
                     bundle: .module,
                     comment: "tx detail: pre-fork explanation; %@ is the eCash network name")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.x4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x4)
    }

    private var heroIcon: Icon {
        if tx.isSidechainDeposit || tx.isSidechainWithdrawal { return Icon.sidechains }
        return tx.isReceived ? Icon.receive : Icon.send
    }
    private var heroTint: Color {
        if tx.isSidechainDeposit || tx.isSidechainWithdrawal { return Theme.Colors.accentTint }
        return tx.isReceived ? Theme.Colors.positiveTint : Theme.Colors.bg2
    }
    private var heroGlyph: Color {
        if tx.isSidechainDeposit || tx.isSidechainWithdrawal { return Theme.Colors.accent }
        return tx.isReceived ? Theme.Colors.positive : Theme.Colors.text1
    }

    // MARK: - Sidechain deposit

    /// Where a deposit went: the sidechain (name + slot) and the sidechain address credited, as
    /// written on-chain. The address is shown in full: it's the only way to check the right
    /// account got the coins.
    private func depositCard(slot: Int32) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            rowText("Sidechain", sidechainName.map { name in
                Text("\(name) · slot \(String(slot))", bundle: .module,
                     comment: "tx detail: sidechain name and slot; %1$@ name, %2$@ slot number")
            } ?? Text("Slot \(String(slot))", bundle: .module, comment: "sidechain slot number; %@ is 0-255"))
            if let address = tx.sidechainDepositAddress {
                hairline
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text("Sidechain address", bundle: .module, comment: "tx detail: address a deposit credits")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text2)
                    Text(verbatim: address)
                        .font(.jbMono(13, .regular))
                        .foregroundStyle(Theme.Colors.text0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    // MARK: - Sidechain withdrawal

    /// The mainchain this sidechain wallet withdraws to ("Betanet" for betanet Thunder).
    private var mainchainName: String {
        SidechainWalletNetwork.mainchain(ofSidechainWallet: network).map { NetworkRegistry.params(for: $0).displayName } ?? ""
    }

    /// Where a withdrawal pays out, and what happens next — the wait is the thing to know.
    private var withdrawalCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            if let address = tx.sidechainWithdrawalAddress, !address.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text("Pays out to", bundle: .module, comment: "tx detail: mainchain address a withdrawal pays")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text2)
                    Text(verbatim: address)
                        .font(.jbMono(13, .regular))
                        .foregroundStyle(Theme.Colors.text0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                hairline
            }
            withdrawalStatusView
            hairline
            Text("The coins have left this wallet. They arrive on \(mainchainName) once miners approve the withdrawal, which takes months — about 3 at best. If a batch expires it goes back in line.",
                 bundle: .module, comment: "tx detail: what happens after a withdrawal; %@ is the mainchain name")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
        .task {
            guard !withdrawalStatusLoaded, let load = loadWithdrawalStatus else { return }
            withdrawalStatus = await load()
            withdrawalStatusLoaded = true
        }
    }

    /// The live stage, with the vote's progress while miners are voting.
    @ViewBuilder private var withdrawalStatusView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("Status", bundle: .module, comment: "tx detail: withdrawal status label")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text2)
            switch withdrawalStatus {
            case .none:
                if withdrawalStatusLoaded {
                    Text("Couldn't check right now.", bundle: .module, comment: "withdrawal status unavailable")
                        .textStyle(.sm).foregroundStyle(Theme.Colors.text1)
                } else {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                }
            case .confirming:
                statusLine(Text("Waiting for the \(sidechainDisplayName) transaction to confirm", bundle: .module,
                                comment: "withdrawal status: sidechain tx unconfirmed; %@ is the sidechain name"))
            case .waitingForBatch:
                statusLine(Text("Waiting to join a withdrawal batch", bundle: .module,
                                comment: "withdrawal status: not yet in an M6 batch"))
                Text("\(sidechainDisplayName) puts withdrawals into a batch when none is being voted on. Then the vote starts.",
                     bundle: .module, comment: "withdrawal status explanation; %@ is the sidechain name")
                    .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
            case let .voting(_, votes, needed, expiry):
                statusLine(Text("Miners voting", bundle: .module, comment: "withdrawal status: batch being voted on"))
                ProgressView(value: withdrawalStatus?.voteFraction ?? 0)
                    .tint(Theme.Colors.accent)
                Text("\(String(votes)) / \(String(needed)) votes", bundle: .module,
                     comment: "vote progress; %1$@ votes so far, %2$@ needed")
                    .textStyle(.xs).foregroundStyle(Theme.Colors.text1)
                if let expiry {
                    HStack(spacing: Theme.Space.x1) {
                        Text("Batch expires in", bundle: .module, comment: "withdrawal batch expiry label, before a duration")
                        ApproximateDurationText(duration: ApproximateDuration(blocks: expiry))
                    }
                    .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                }
                if withdrawalStatus?.canStillPass == false {
                    Text("This batch can no longer get enough votes in time. When it expires, the withdrawal goes back in line for the next one.",
                         bundle: .module, comment: "withdrawal batch will fail; it will be re-batched")
                        .textStyle(.xs).foregroundStyle(Theme.Colors.warning)
                }
            case .paid:
                statusLine(Text("Paid out on \(mainchainName)", bundle: .module,
                                comment: "withdrawal status: batch passed and paid; %@ is the mainchain name"),
                           done: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(_ text: Text, done: Bool = false) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Image(icon: done ? Icon.check : Icon.pending)
                .resizable().scaledToFit().frame(width: 14, height: 14)
                .foregroundStyle(done ? Theme.Colors.positive : Theme.Colors.accent)
            text.textStyle(.sm).foregroundStyle(Theme.Colors.text0)
        }
    }

    private var sidechainDisplayName: String { NetworkRegistry.params(for: network).displayName }

    // MARK: - CoinNews hero

    /// CoinNews txs are 0-value `OP_RETURN`s — the amount is just the fee, so leading with a big
    /// "0.00000000" is noise. Instead: the news glyph, the action ("CoinNews Comment" / "Upvote" /
    /// …), the status pill, and the date. The raw chain rows live in `detailsDisclosure` below.
    private var coinNewsHero: some View {
        VStack(spacing: Theme.Space.x3) {
            ZStack {
                Circle().fill(Theme.Colors.accentTint)
                Image(icon: Icon.news)
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(Theme.Colors.accent)
            }
            .frame(width: 64, height: 64)

            Text(verbatim: coinNewsTitle)
                .font(.satoshi(22, .semibold))
                .foregroundStyle(Theme.Colors.text0)

            statusPill

            if let epoch = tx.timestampEpochSeconds {
                Text(verbatim: Self.fullDate(epoch))
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x4)
    }

    /// "CoinNews Comment" / "Upvote" / "Downvote" / "Story" / "Topic" (upvote vs downvote spelled out
    /// here — the Activity row collapses both to "vote").
    private var coinNewsTitle: String {
        switch tx.coinNewsKind {
        case "topic": return "CoinNews Topic"
        case "story": return "CoinNews Story"
        case "comment": return "CoinNews Comment"
        case "upvote": return "CoinNews Upvote"
        case "downvote": return "CoinNews Downvote"
        default: return "CoinNews Post"
        }
    }

    /// Status pill: amber "Pending" (0 conf) / amber "Confirming" (1–5) / green "Confirmed" (>5).
    private var statusPill: some View {
        HStack(spacing: Theme.Space.x1) {
            Image(icon: (tx.confirmations > 5 || tx.isConfirmedDepthUnknown) ? Icon.check : Icon.pending)
                .resizable().scaledToFit()
                .frame(width: 13, height: 13)
            pillLabel.textStyle(.sm)
        }
        .foregroundStyle(pillColor)
        .padding(.horizontal, Theme.Space.x3)
        .padding(.vertical, Theme.Space.x1)
        .background(pillTint, in: Capsule())
    }

    private var pillLabel: Text {
        if tx.isConfirmedDepthUnknown {   // in a block, depth not reported by the node
            return Text("Confirmed", bundle: .module, comment: "tx status pill: confirmed")
        }
        if tx.confirmations == 0 {
            return Text("Pending", bundle: .module, comment: "tx status pill: unconfirmed")
        }
        if tx.confirmations > 5 {
            return Text("Confirmed", bundle: .module, comment: "tx status pill: confirmed")
        }
        return Text("Confirming", bundle: .module, comment: "tx status pill: settling")
    }

    private var isSettled: Bool { tx.confirmations > 5 || tx.isConfirmedDepthUnknown }
    private var pillColor: Color { isSettled ? Theme.Colors.positive : Theme.Colors.warning }
    private var pillTint: Color { isSettled ? Theme.Colors.positiveTint : Theme.Colors.warningTint }

    // MARK: - Details

    /// CoinNews: the raw chain rows, collapsed behind a tap. `DisclosureGroup` renders on both
    /// platforms (SwiftUI on iOS, a Compose expandable on Android).
    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            detailRows.padding(.top, Theme.Space.x3)
        } label: {
            Text("Transaction details", bundle: .module, comment: "collapsible raw tx details")
                .textStyle(.button)
                .foregroundStyle(Theme.Colors.text0)
        }
        .tint(Theme.Colors.accent)
        .cardStyle()
    }

    private var detailsCard: some View { detailRows.cardStyle() }

    @ViewBuilder
    private var detailRows: some View {
        VStack(spacing: Theme.Space.x3) {
            row("Amount", "\(amountCoin) \(unitLabel)")
            if !tx.isReceived, let fee = tx.feeSats {
                hairline
                row("Network fee", "\(fee) \(subUnit)s")
                hairline
                row("Total", "\(totalCoin) \(unitLabel)")
                if let rate = tx.feeRatePerVByte() {
                    hairline
                    row("Fee rate", feeRateText(rate))
                }
            }
            hairline
            row("Confirmations", "\(tx.confirmations)")
            if let height = tx.blockHeight {
                hairline
                row("Block height", "\(height)")
            }
            if let vsize = tx.vsize {
                hairline
                row("Size", "\(vsize) vB")
            }
            hairline
            row("Network", NetworkRegistry.params(for: network).displayName)
            if !tx.isReceived {
                hairline
                rowText("Replaceable", tx.isRBF
                        ? Text("Yes (RBF)", bundle: .module, comment: "tx is replaceable")
                        : Text("No", bundle: .module, comment: "tx is not replaceable"))
            }
            ForEach(Array(keyPaths.prefix(Self.maxKeyRows).enumerated()), id: \.offset) { _, entry in
                hairline
                rowText(entry.label, Text(verbatim: entry.path))
            }
            if keyPaths.count > Self.maxKeyRows {
                Text("and \(String(keyPaths.count - Self.maxKeyRows)) more", bundle: .module,
                     comment: "tx detail: more derivation paths than shown; %@ is the count")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// A sweep can spend dozens of our coins; past this the list stops earning its space.
    private static let maxKeyRows = 8

    /// This wallet's keys the tx touched, as labelled derivation paths (`m/84'/1'/0'/0/5`). Empty for
    /// a single-key (WIF) wallet — it has no derivation.
    private var keyPaths: [(label: LocalizedStringKey, path: String)] {
        guard let wallet else { return [] }
        var result: [(label: LocalizedStringKey, path: String)] = []
        for key in tx.ownKeys {
            guard let path = WalletDerivationPath.path(for: wallet, isChange: key.isChange, index: key.index) else { continue }
            let label: LocalizedStringKey = key.isInput ? "Spent from" : (key.isChange ? "Change to" : "Received at")
            result.append((label: label, path: path))
        }
        return result
    }

    private var hairline: some View {
        Rectangle().fill(Theme.Colors.border).frame(height: 1)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        rowText(label, Text(verbatim: value))
    }

    private func rowText(_ label: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x3) {
            Text(label, bundle: .module)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text2)
            Spacer(minLength: Theme.Space.x4)
            value
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Transaction ID

    private var txidCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            HStack {
                Text("TRANSACTION ID", bundle: .module, comment: "tx detail: txid section header")
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
                Spacer()
                Button {
                    Clipboard.copy(tx.txid)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    HStack(spacing: Theme.Space.x1) {
                        Image(icon: copied ? Icon.check : Icon.copy)
                            .resizable().scaledToFit().frame(width: 13, height: 13)
                        (copied
                            ? Text("Copied", bundle: .module, comment: "txid copied")
                            : Text("Copy", bundle: .module, comment: "tx detail: copy txid"))
                            .textStyle(.xs)
                    }
                    .foregroundStyle(copied ? Theme.Colors.positive : Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }
            Text(verbatim: tx.txid)
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text0)
        }
        .cardStyle()
    }

    // MARK: - Explorer action

    @ViewBuilder
    private var explorerButton: some View {
        if let url = URL(string: RemoteServiceOverrides.explorerURL(for: tx.txid, on: explorerNetwork)) {
            Link(destination: url) {
                HStack(spacing: Theme.Space.x2) {
                    Text("View on block explorer", bundle: .module, comment: "tx detail: open block explorer")
                        .textStyle(.button)
                    Image(icon: Icon.send)   // north-east arrow = open external
                        .resizable().scaledToFit()
                        .frame(width: 15, height: 15)
                }
                .foregroundStyle(Theme.Colors.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.x4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.accent))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Derived values

    /// Which chain's explorer shows this txid. A deposit seen from a sidechain wallet is a MAINCHAIN
    /// transaction, so it opens the mainchain explorer; the sidechain's would 404.
    private var explorerNetwork: WalletNetwork {
        if tx.isSidechainDeposit, let mainchain = SidechainWalletNetwork.mainchain(ofSidechainWallet: network) {
            return mainchain
        }
        return network
    }

    /// Recipient amount (net minus fee for sends), signed like the row. For a self-transfer there is
    /// no recipient — netting the fee out would render the whole transaction as 0 — so the amount is
    /// the fee, which is the only value that actually left the wallet. See `WalletTx.isSelfTransfer`.
    private var amountCoin: String {
        if tx.isSelfTransfer, let moved = tx.receivedSats, moved > 0 {
            return Amount(sats: moved).formattedCoin()   // moved between our own addresses
        }
        let sign = tx.isReceived ? "+" : "-"
        var sats = abs(tx.netSats)
        if !tx.isReceived, !tx.isSelfTransfer, let fee = tx.feeSats, fee <= sats {
            sats = sats - fee
        }
        return "\(sign)\(Amount(sats: sats).formattedCoin())"
    }

    /// Total outflow for sends (recipient amount + fee = |netSats|).
    private var totalCoin: String {
        "-\(Amount(sats: abs(tx.netSats)).formattedCoin())"
    }

    /// "1.42 sat/vB" — 2 decimals, formatted without `String(format:)` (keeps it transpile-safe).
    private func feeRateText(_ rate: Double) -> String {
        let hundredths = Int((rate * 100).rounded())
        let frac = hundredths % 100
        let fracStr = frac < 10 ? "0\(frac)" : "\(frac)"
        return "\(hundredths / 100).\(fracStr) \(subUnit)/vB"
    }

    private static func fullDate(_ epoch: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}

private extension View {
    /// The shared card chrome: bg1 fill + hairline border, rounded.
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
    }
}
