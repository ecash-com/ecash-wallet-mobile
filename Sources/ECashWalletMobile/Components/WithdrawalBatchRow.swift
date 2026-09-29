// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// A withdrawal batch (BIP300 M6) that miners are voting on: its id, vote progress, and either how
/// soon it could pass or that it can't pass before it expires.
struct WithdrawalBatchRow: View {
    let bundle: WithdrawalBundleProposal
    let progress: SidechainsViewModel.WithdrawalProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("Batch \(Self.shortId(bundle.m6id))", bundle: .module,
                 comment: "withdrawal batch label; %@ is a shortened id")
                .textStyle(.mono)
                .foregroundStyle(Theme.Colors.text0)
            if let progress {
                VoteProgressView(progress: progress.votes)
                outlook(progress)
            }
        }
        .padding(.vertical, Theme.Space.x1)
    }

    @ViewBuilder private func outlook(_ progress: SidechainsViewModel.WithdrawalProgress) -> some View {
        if progress.votes.remaining == 0 {
            Text("Approved. Paying out on the mainchain.", bundle: .module,
                 comment: "withdrawal batch reached its vote threshold")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.positive)
        } else if progress.canStillPass {
            VStack(alignment: .leading, spacing: 2) {
                Text("Could pass in, at the earliest:", bundle: .module,
                     comment: "withdrawal batch best-case time; a duration follows on the next line")
                ApproximateDurationText(duration: ApproximateDuration(blocks: progress.blocksToPass))
            }
            .textStyle(.xs)
            .foregroundStyle(Theme.Colors.text2)
        } else {
            // Not lost: an expired batch's withdrawals go back into the queue for the next batch.
            Text("Can't collect enough votes before it expires. Its withdrawals will go into a later batch.",
                 bundle: .module, comment: "withdrawal batch will expire before passing")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.warning)
        }
    }

    /// `aa769fec…ced4`: enough to tell batches apart, short enough for one line.
    static func shortId(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return "\(hex.prefix(8))…\(hex.suffix(4))"
    }
}
