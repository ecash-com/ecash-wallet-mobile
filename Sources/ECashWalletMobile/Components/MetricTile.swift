// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One network metric: label over a big mono value, with an ⓘ that opens its definition. The whole
/// tile is the button — the definition is part of the number, not a footnote.
struct MetricTile: View {
    let metric: DashboardMetric
    /// nil → "—": the metric isn't known, which is not the same as zero.
    let value: String?
    var unit: String? = nil
    let onInfo: () -> Void

    var body: some View {
        Button(action: onInfo) {
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                HStack(spacing: Theme.Space.x1) {
                    Text(metric.shortTitle, bundle: .module)
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                        .lineLimit(1)
                    Image(icon: Icon.info).resizable().scaledToFit().frame(width: 11, height: 11)
                        .foregroundStyle(Theme.Colors.text2)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x1) {
                    Text(verbatim: value ?? "—")
                        .font(.jbMono(20, .medium))
                        .foregroundStyle(Theme.Colors.text0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let unit, value != nil {
                        Text(verbatim: unit)
                            .textStyle(.xs)
                            .foregroundStyle(Theme.Colors.text2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x3)
            .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
    }
}
