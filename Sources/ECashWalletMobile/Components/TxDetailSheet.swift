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

    private var hero: some View {
        VStack(spacing: Theme.Space.x3) {
            ZStack {
                Circle().fill(tx.isReceived ? Theme.Colors.positiveTint : Theme.Colors.bg2)
                Image(icon: tx.isReceived ? Icon.receive : Icon.send)
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(tx.isReceived ? Theme.Colors.positive : Theme.Colors.text1)
            }
            .frame(width: 64, height: 64)

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
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x4)
    }

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
                .font(.grotesk(22, .semibold))
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
            Image(icon: tx.confirmations > 5 ? Icon.check : Icon.pending)
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
        if tx.confirmations == 0 {
            return Text("Pending", bundle: .module, comment: "tx status pill: unconfirmed")
        }
        if tx.confirmations > 5 {
            return Text("Confirmed", bundle: .module, comment: "tx status pill: confirmed")
        }
        return Text("Confirming", bundle: .module, comment: "tx status pill: settling")
    }

    private var pillColor: Color { tx.confirmations > 5 ? Theme.Colors.positive : Theme.Colors.warning }
    private var pillTint: Color { tx.confirmations > 5 ? Theme.Colors.positiveTint : Theme.Colors.warningTint }

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
                row("Network fee", "\(fee) sats")
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
        }
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
        if let url = URL(string: RemoteServiceOverrides.explorerURL(for: tx.txid, on: network)) {
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

    /// Recipient amount (net minus fee for sends), signed like the row.
    private var amountCoin: String {
        let sign = tx.isReceived ? "+" : "-"
        var sats = abs(tx.netSats)
        if !tx.isReceived, let fee = tx.feeSats, fee <= sats {
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
        return "\(hundredths / 100).\(fracStr) sat/vB"
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
