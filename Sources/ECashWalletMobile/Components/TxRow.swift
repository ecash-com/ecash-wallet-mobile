// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// One transaction row — shared by the Activity tab and the Home preview. Two lines:
///
///   [chip]  Received  ⟨Pending⟩        +0.00500000 sBTC
///           Today 14:02 · 1 conf                  ≈ €4.12
///
/// `fiatText` is the precomputed fiat value for this tx (caller derives it from the price
/// service); `nil` on networks without a price provider (testnets) → no fiat line, never a fake
/// placeholder. The miner fee lives on the tx-detail screen. Android (Compose) discipline still
/// applies: shallow modifier stacks (one font + one color per Text), a single Spacer.
struct TxRow: View {
    let tx: WalletTx
    let unitLabel: String
    var fiatText: String? = nil

    var body: some View {
        HStack(spacing: Theme.Space.x3) {
            chip

            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                HStack(spacing: Theme.Space.x2) {
                    titleLabel
                    if isPending {
                        Text("Pending", bundle: .module, comment: "tx row: unconfirmed tag")
                            .font(.jbMono(11, .medium))
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
                Text(metaText, bundle: .module)
                    .font(.jbMono(11, .regular))
                    .foregroundStyle(Theme.Colors.text2)
                    .singleLine()
            }

            Spacer(minLength: Theme.Space.x2)

            VStack(alignment: .trailing, spacing: Theme.Space.x2) {
                HStack(spacing: Theme.Space.x1) {
                    Text(verbatim: amountText)
                        .font(.jbMono(14, .medium))
                        .foregroundStyle(tx.isReceived ? Theme.Colors.positive : Theme.Colors.text0)
                    Text(verbatim: unitLabel)
                        .font(.jbMono(11, .regular))
                        .foregroundStyle(Theme.Colors.text2)
                }
                // Fiat value for priced networks (mainnet); absent on testnets / before a quote.
                if let fiatText {
                    Text(verbatim: "≈ \(fiatText)")
                        .font(.jbMono(12, .regular))
                        .foregroundStyle(Theme.Colors.text2)
                }
            }
        }
    }
    // No vertical padding here: the Activity `List` adds its own row insets (doubling up reads
    // too airy on iOS); the Home preview adds its own spacing at the call site instead.

    private var isPending: Bool { tx.confirmations == 0 }

    /// Title line: CoinNews posts read "CoinNews story / topic / …" (a 0-value OP_RETURN is not a
    /// real "Sent"); everything else is the usual Received/Sent.
    @ViewBuilder private var titleLabel: some View {
        if let kind = tx.coinNewsKind {
            Text(verbatim: "CoinNews \(Self.displayKind(kind))")
                .font(.grotesk(16, .semibold))
                .foregroundStyle(Theme.Colors.text0)
        } else if tx.isSelfTransfer {
            // A split or self-sweep didn't pay anyone — calling it "Sent" next to a fee-sized
            // amount is what makes it look like a failed send.
            Text("Sent to yourself", bundle: .module, comment: "tx row: coins moved between the user's own addresses (split / self-sweep)")
                .font(.grotesk(16, .semibold))
                .foregroundStyle(Theme.Colors.text0)
        } else {
            (tx.isReceived
                ? Text("Received", bundle: .module, comment: "tx row: incoming")
                : Text("Sent", bundle: .module, comment: "tx row: outgoing"))
                .font(.grotesk(16, .semibold))
                .foregroundStyle(Theme.Colors.text0)
        }
    }

    private static func displayKind(_ kind: String) -> String {
        switch kind {
        case "story": return "story"
        case "topic": return "topic"
        case "comment": return "comment"
        case "upvote", "downvote": return "vote"
        default: return "post"
        }
    }

    /// Direction chip: tinted circle + glyph. CoinNews posts use the news glyph in the brand accent;
    /// pending sends go amber, like the mock.
    private var chip: some View {
        ZStack {
            Circle().fill(chipTint)
            Image(icon: chipIcon)
                .resizable().scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(chipGlyph)
        }
        .frame(width: 36, height: 36)
    }

    private var chipIcon: Icon {
        if tx.isCoinNews { return Icon.news }
        return tx.isReceived ? Icon.receive : Icon.send
    }

    private var chipTint: Color {
        if tx.isCoinNews { return Theme.Colors.accentTint }
        if isPending { return Theme.Colors.warningTint }
        return tx.isReceived ? Theme.Colors.positiveTint : Theme.Colors.bg2
    }

    private var chipGlyph: Color {
        if tx.isCoinNews { return Theme.Colors.accent }
        if isPending { return Theme.Colors.warning }
        return tx.isReceived ? Theme.Colors.positive : Theme.Colors.text1
    }

    /// "Today 14:02 · 3 conf" while settling; "· Confirmed" once past 5 confs (the exact count
    /// stops mattering); unconfirmed (no timestamp): "Just now · 0 conf".
    // LocalizedStringKey so the copy localizes via the module catalog; `dateText` stays a plain
    // String interpolated in (locale-aware date formatting is a later refinement — §10 note).
    private var metaText: LocalizedStringKey {
        // Confirmed with no known depth (Thunder): say so and stop. Printing "1 conf" would present
        // a floor as a fact, and the only date we hold is when this device first saw the tx — which
        // for a restored wallet is "today" for transactions that are years old.
        if tx.isConfirmedDepthUnknown {
            return "Confirmed"
        }
        if tx.confirmations > 5 {
            return "\(dateText) · Confirmed"
        }
        return "\(dateText) · \(Int(tx.confirmations)) conf"
    }

    private var dateText: String {
        guard let epoch = tx.timestampEpochSeconds else {
            return "Just now"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let calendar = Calendar.current
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) {
            return "Today \(time.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(time.string(from: date))"
        }
        let day = DateFormatter()
        day.dateFormat = "MMM d"
        return day.string(from: date)
    }

    /// Recipient-amount magnitude (net minus fee for sends — the fee is itemized on the
    /// tx-detail screen). e.g. "+0.01250000" / "-0.00400000".
    private var amountText: String {
        // A self-transfer (split / self-sweep) has no recipient, so neither of the usual answers
        // fits: `netSats` is just the fee, and netting the fee out of it gives exactly 0. What
        // happened is that a balance MOVED to another of our addresses — so show that, unsigned,
        // since nothing entered or left the wallet. The fee is in the detail sheet.
        if tx.isSelfTransfer, let moved = tx.receivedSats, moved > 0 {
            return Amount(sats: moved).formattedCoin()
        }
        let sign = tx.isReceived ? "+" : "-"
        var sats = abs(tx.netSats)
        // Subtracting the fee answers "what did the recipient get" — right for a real send.
        if !tx.isReceived, !tx.isSelfTransfer, let fee = tx.feeSats, fee <= sats {
            sats = sats - fee
        }
        return "\(sign)\(Amount(sats: sats).formattedCoin())"
    }
}
