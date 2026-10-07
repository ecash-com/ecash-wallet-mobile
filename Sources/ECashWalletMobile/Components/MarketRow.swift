// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One asset: name + ticker, price, 24h change (arrow + colour), and — on the full table — volume and
/// venue. Not tappable on purpose: no links to trading venues (App Review 3.1.5, plan §3.6).
struct MarketRow: View {
    let quote: MarketQuote
    var detailed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: quote.name)
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)
                    .lineLimit(1)
                Text(verbatim: detailed ? "\(quote.ticker) · \(quote.source)" : quote.ticker)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: DashboardFormat.usd(quote.price))
                    .font(.jbMono(14, .medium))
                    .foregroundStyle(Theme.Colors.text0)
                    .lineLimit(1)
                HStack(spacing: Theme.Space.x2) {
                    if detailed, let volume = quote.volume24h {
                        Text(verbatim: "vol \(DashboardFormat.compactUSD(volume))")
                            .textStyle(.xs)
                            .foregroundStyle(Theme.Colors.text2)
                    }
                    if let change = quote.change24h {
                        Text(verbatim: DashboardFormat.percentChange(change))
                            .textStyle(.xs)
                            .foregroundStyle(change < 0 ? Theme.Colors.negative : Theme.Colors.positive)
                    }
                }
                .lineLimit(1)
            }
        }
    }
}
