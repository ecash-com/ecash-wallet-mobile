// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The Home-header wallet switcher: initial-avatar + label + chevron in a pill. Tapping opens
/// the wallet manager sheet. Pure presentation — selection state lives in AppState.
struct WalletSwitcherPill: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.x2) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.xs)
                        .fill(Theme.Colors.accent)
                    Text(initial)
                        .font(.grotesk(13, .bold))
                        .foregroundStyle(Theme.Colors.accentText)
                }
                .frame(width: 24, height: 24)

                Text(label)
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)

                Image(icon: Icon.expand)
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Theme.Colors.text1)
            }
            .padding(.vertical, Theme.Space.x2)
            .padding(.horizontal, Theme.Space.x3)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var initial: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "•" }
        return String(trimmed.prefix(1)).uppercased()
    }
}
