// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Compact "Get coins" pill for the home header (trailing). Only shown on networks with a faucet
/// (`FaucetRegistry`) — i.e. signet — so it never appears on Bitcoin mainnet. Tapping opens the
/// faucet sheet.
struct FaucetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.x1) {
                Image(icon: Icon.faucet)
                    .resizable().scaledToFit()
                    .frame(width: 13, height: 13)
                Text("Get coins", bundle: .module, comment: "signet faucet button: request test coins")
                    .textStyle(.xs)
            }
            .foregroundStyle(Theme.Colors.accent)
            .padding(.horizontal, Theme.Space.x3)
            .padding(.vertical, Theme.Space.x2)
            .background(Theme.Colors.accentTint, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
