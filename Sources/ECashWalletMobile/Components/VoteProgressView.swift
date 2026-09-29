// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// A vote bar with "808 / 1,008 votes" under it.
struct VoteProgressView: View {
    let progress: SidechainsViewModel.VoteProgress

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            ProgressView(value: progress.fraction)
                .tint(Theme.Colors.accent)
            Text("\(String(progress.votes)) / \(String(progress.threshold)) votes",
                 bundle: .module, comment: "vote progress; %1$@ votes so far, %2$@ needed")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }
}
