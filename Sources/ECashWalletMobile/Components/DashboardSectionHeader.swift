// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A dashboard card's header: an overline title (with an optional trailing note, e.g. the network
/// name) and an optional "See all" push.
struct DashboardSectionHeader: View {
    let title: LocalizedStringKey
    var note: String? = nil
    var route: DashboardRoute? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x2) {
            Text(title, bundle: .module)
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            if let note {
                Text(verbatim: "· \(note.uppercased())")
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
            }
            Spacer(minLength: Theme.Space.x2)
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 2) {
                        Text("See all", bundle: .module, comment: "dashboard: open a section's full screen")
                            .textStyle(.xs)
                        Image(icon: Icon.disclosure).resizable().scaledToFit().frame(width: 12, height: 12)
                    }
                    .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension View {
    /// Dashboard card chrome: `bg1` fill, hairline border, rounded — the same card look as tx detail.
    func dashboardCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
    }
}
