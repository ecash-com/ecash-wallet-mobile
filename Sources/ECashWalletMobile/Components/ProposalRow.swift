// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// A sidechain being voted in, with its progress toward activation.
struct ProposalRow: View {
    let proposal: SidechainProposal
    let progress: SidechainsViewModel.VoteProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: proposal.title)
                    .textStyle(.h3)
                    .foregroundStyle(Theme.Colors.text0)
                Spacer()
                SlotLabel(slot: proposal.slot)
            }
            if !proposal.description.isEmpty {
                Text(verbatim: proposal.description)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
                    .lineLimit(2)
            }
            if let progress {
                VoteProgressView(progress: progress)
            } else {
                Text("\(String(proposal.voteCount)) votes", bundle: .module,
                     comment: "proposal vote count when the threshold is unknown; %@ is a number")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
            }
        }
        .padding(.vertical, Theme.Space.x1)
    }
}
