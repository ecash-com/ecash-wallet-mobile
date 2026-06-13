// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Transaction detail, shown as a sheet when an activity row is tapped. Itemizes what the row
/// summarizes: recipient amount, miner fee (sends), total, status, time, RBF flag, and the
/// txid with copy + open-in-explorer (URL template from `NetworkRegistry`, Golden Rule §4).
struct TxDetailSheet: View {
    @Environment(\.dismiss) var dismiss
    let tx: WalletTx
    let unitLabel: String
    let network: WalletNetwork

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.bg0.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.x4) {
                        header

                        VStack(alignment: .leading, spacing: Theme.Space.x3) {
                            detailRow(label: "Amount", value: "\(amountCoin) \(unitLabel)")
                            if !tx.isReceived, let fee = tx.feeSats {
                                detailRow(label: "Network fee", value: "\(fee) sats")
                                detailRow(label: "Total", value: "\(totalCoin) \(unitLabel)")
                            }
                            detailRow(label: "Status", value: statusText)
                            if let epoch = tx.timestampEpochSeconds {
                                detailRow(label: "Time", value: Self.fullDate(epoch))
                            }
                            if !tx.isReceived {
                                detailRow(label: "Replaceable", value: tx.isRBF ? "Yes (RBF)" : "No")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.x4)
                        .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.Colors.border, lineWidth: 1)
                        )

                        txidSection
                    }
                    .padding(Theme.Space.gutter)
                }
            }
            .navigationTitle("Transaction")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { dismiss() } label: { Text("Done") }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.x3) {
            ZStack {
                Circle().fill(tx.isReceived ? Theme.Colors.positiveTint : Theme.Colors.bg2)
                Image(icon: tx.isReceived ? Icon.receive : Icon.send)
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(tx.isReceived ? Theme.Colors.positive : Theme.Colors.text1)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.isReceived ? "Received" : "Sent")
                    .textStyle(.h2)
                    .foregroundStyle(Theme.Colors.text0)
                Text(statusText)
                    .textStyle(.xs)
                    .foregroundStyle(tx.confirmations == 0 ? Theme.Colors.warning : Theme.Colors.text2)
            }
        }
    }

    private var txidSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("TRANSACTION ID")
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            Text(tx.txid)
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text0)
            HStack(spacing: Theme.Space.x3) {
                Button {
                    Clipboard.copy(tx.txid)
                } label: {
                    HStack(spacing: Theme.Space.x1) {
                        Image(icon: Icon.copy).resizable().scaledToFit().frame(width: 14, height: 14)
                        Text("Copy").textStyle(.sm)
                    }
                    .foregroundStyle(Theme.Colors.text1)
                }
                .buttonStyle(.plain)

                if let url = URL(string: NetworkRegistry.explorerURL(for: tx.txid, on: network)) {
                    Link(destination: url) {
                        HStack(spacing: Theme.Space.x1) {
                            Image(icon: Icon.qr).resizable().scaledToFit().frame(width: 14, height: 14)
                            Text("View in explorer").textStyle(.sm)
                        }
                        .foregroundStyle(Theme.Colors.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.x4)
        .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            Text(value)
                .font(.jbMono(14, .regular))
                .foregroundStyle(Theme.Colors.text0)
        }
    }

    private var statusText: String {
        if tx.confirmations == 0 { return "Pending · 0 conf" }
        if tx.confirmations > 5 { return "Confirmed · \(tx.confirmations) conf" }
        return "\(tx.confirmations) conf"
    }

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

    private static func fullDate(_ epoch: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
