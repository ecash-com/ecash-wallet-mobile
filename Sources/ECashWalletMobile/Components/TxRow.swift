// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// One transaction row — shared by the Activity tab and the Home preview. Two lines:
///
///   [chip]  Received  ⟨Pending⟩        +0.00500000 sBTC
///           Today 14:02 · 1 conf                  $0.00
///
/// Fiat is a $0.00 placeholder until the rate service lands; the miner fee lives on the
/// upcoming tx-detail screen. Android (Compose) discipline still applies: shallow modifier
/// stacks (one font + one color per Text), a single Spacer, no per-child flexible frames.
struct TxRow: View {
    let tx: WalletTx
    let unitLabel: String

    var body: some View {
        HStack(spacing: Theme.Space.x3) {
            chip

            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                HStack(spacing: Theme.Space.x2) {
                    Text(tx.isReceived ? "Received" : "Sent")
                        .font(.grotesk(16, .semibold))
                        .foregroundStyle(Theme.Colors.text0)
                    if isPending {
                        Text("Pending")
                            .font(.jbMono(11, .medium))
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
                Text(metaText)
                    .font(.jbMono(11, .regular))
                    .foregroundStyle(Theme.Colors.text2)
                    .singleLine()
            }

            Spacer(minLength: Theme.Space.x2)

            VStack(alignment: .trailing, spacing: Theme.Space.x2) {
                HStack(spacing: Theme.Space.x1) {
                    Text(amountText)
                        .font(.jbMono(14, .medium))
                        .foregroundStyle(tx.isReceived ? Theme.Colors.positive : Theme.Colors.text0)
                    Text(unitLabel)
                        .font(.jbMono(11, .regular))
                        .foregroundStyle(Theme.Colors.text2)
                }
                // Fiat placeholder until the rate service (Settings currency) lands.
                Text("$0.00")
                    .font(.jbMono(12, .regular))
                    .foregroundStyle(Theme.Colors.text2)
            }
        }
    }
    // No vertical padding here: the Activity `List` adds its own row insets (doubling up reads
    // too airy on iOS); the Home preview adds its own spacing at the call site instead.

    private var isPending: Bool { tx.confirmations == 0 }

    /// Direction chip: tinted circle + direction glyph. Pending sends go amber, like the mock.
    private var chip: some View {
        ZStack {
            Circle().fill(chipTint)
            Image(icon: tx.isReceived ? Icon.receive : Icon.send)
                .resizable().scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(chipGlyph)
        }
        .frame(width: 36, height: 36)
    }

    private var chipTint: Color {
        if isPending { return Theme.Colors.warningTint }
        return tx.isReceived ? Theme.Colors.positiveTint : Theme.Colors.bg2
    }

    private var chipGlyph: Color {
        if isPending { return Theme.Colors.warning }
        return tx.isReceived ? Theme.Colors.positive : Theme.Colors.text1
    }

    /// "Today 14:02 · 3 conf" while settling; "· Confirmed" once past 5 confs (the exact count
    /// stops mattering); unconfirmed (no timestamp): "Just now · 0 conf".
    private var metaText: String {
        if tx.confirmations > 5 {
            return "\(dateText) · Confirmed"
        }
        return "\(dateText) · \(tx.confirmations) conf"
    }

    private var dateText: String {
        guard let epoch = tx.timestampEpochSeconds else { return "Just now" }
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
        let sign = tx.isReceived ? "+" : "-"
        var sats = abs(tx.netSats)
        if !tx.isReceived, let fee = tx.feeSats, fee <= sats {
            sats = sats - fee
        }
        return "\(sign)\(Amount(sats: sats).formattedCoin())"
    }
}
