// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Placeholder bars for a card with nothing to show yet — real row height, no spinner (plan §3.4).
struct DashboardSkeleton: View {
    var rows: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            ForEach(0..<rows, id: \.self) { index in
                RoundedRectangle(cornerRadius: Theme.Radius.xs)
                    .fill(Theme.Colors.bg2)
                    .frame(height: 14)
                    .frame(maxWidth: index == rows - 1 ? 180 : .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel(Text("Loading", bundle: .module, comment: "dashboard card loading"))
    }
}

/// The line under a card saying how fresh it is: "Updated 15:25", or — when the last refresh
/// failed — the same in `warning` with "couldn't refresh". Hidden while there's nothing to date.
struct DashboardFreshness: View {
    let updatedAt: Int64?
    let stale: Bool
    var source: String? = nil

    var body: some View {
        if let updatedAt {
            HStack(spacing: Theme.Space.x1) {
                if stale {
                    Text("Updated \(DashboardFormat.time(updatedAt)) · couldn't refresh", bundle: .module,
                         comment: "dashboard card: stale data; %@ is a time")
                } else {
                    Text("Updated \(DashboardFormat.time(updatedAt))", bundle: .module,
                         comment: "dashboard card freshness; %@ is a time")
                }
                if let source {
                    Text(verbatim: "· \(source)")
                }
            }
            .textStyle(.xs)
            .foregroundStyle(stale ? Theme.Colors.warning : Theme.Colors.text2)
            .lineLimit(1)
        }
    }
}

/// "Unavailable" for a card whose source failed with nothing cached — never a zero (plan §3.4).
struct DashboardUnavailable: View {
    var body: some View {
        Text("Unavailable right now. Pull to retry.", bundle: .module, comment: "dashboard card: source failed")
            .textStyle(.sm)
            .foregroundStyle(Theme.Colors.text2)
    }
}
