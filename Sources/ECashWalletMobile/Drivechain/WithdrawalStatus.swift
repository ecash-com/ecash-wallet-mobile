// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where a regular (BIP300) withdrawal is on its way from a sidechain to the mainchain.
///
/// The path, and how each step is observed:
/// 1. **confirming** — the sidechain transaction carrying the withdrawal output isn't in a block yet.
/// 2. **waitingForBatch** — the output is in a block but unspent: the sidechain hasn't put it in a
///    withdrawal batch (M6) yet. A batch forms only when none is pending, so this can take a while.
/// 3. **voting** — the output is spent by a batch the enforcer still lists: miners are voting on it.
/// 4. **paid** — spent by a batch the enforcer no longer lists. A batch that FAILS doesn't end here:
///    thunder-rust puts its withdrawal outputs back as unspent (re-batched), which reads as step 2 again.
enum WithdrawalStatus: Equatable {
    case confirming
    case waitingForBatch
    case voting(m6id: String, votes: Int, votesNeeded: Int, blocksUntilExpiry: Int?)
    case paid(m6id: String)

    /// 0…1 — how far the vote is towards passing.
    var voteFraction: Double? {
        guard case let .voting(_, votes, needed, _) = self, needed > 0 else { return nil }
        return min(1, Double(votes) / Double(needed))
    }

    /// False when even an upvote in every block left can't pass the batch before it expires: it will
    /// fail and the withdrawal goes back in line. Not lost — but not soon either.
    var canStillPass: Bool {
        guard case let .voting(_, votes, needed, expiry?) = self else { return true }
        return max(0, needed - votes) <= expiry
    }

    /// Decide the status from what the index and the enforcer report. Pure, so every step is testable
    /// from fixtures.
    ///
    /// - `outspend`: the withdrawal output's spend state on the sidechain index.
    /// - `proposals`: the enforcer's pending withdrawal batches for the sidechain's slot.
    /// - `inclusionThreshold` / `maxAge`: the enforcer's BIP300 constants. A batch passes with MORE than
    ///   `inclusionThreshold` votes (`votes > threshold`), so `threshold + 1` are needed.
    static func resolve(transactionConfirmed: Bool,
                        outspend: ThunderEsploraOutspend,
                        proposals: [WithdrawalBundleProposal],
                        inclusionThreshold: Int,
                        maxAge: Int,
                        mainchainTipHeight: Int?) -> WithdrawalStatus {
        guard transactionConfirmed else { return .confirming }
        guard let m6id = outspend.withdrawalBundleM6id else { return .waitingForBatch }
        guard let proposal = proposals.first(where: { $0.m6id.lowercased() == m6id }) else {
            return .paid(m6id: m6id)
        }
        let expiry = mainchainTipHeight.map { max(0, maxAge - ($0 - proposal.proposalHeight)) }
        return .voting(m6id: m6id, votes: proposal.voteCount, votesNeeded: inclusionThreshold + 1,
                       blocksUntilExpiry: expiry)
    }
}

/// Looks up a Thunder withdrawal's status: the sidechain index for the withdrawal output's spend state,
/// the mainchain enforcer for the batch's votes. Needs the Esplora index — the node RPC can't say what
/// spent an output.
struct ThunderWithdrawalTracker {
    let index: ThunderEsploraClient
    let enforcer: any EnforcerFetching
    let slot: Int

    enum TrackerError: Error, Equatable {
        /// The transaction has no withdrawal output (it isn't a withdrawal).
        case notAWithdrawal
    }

    func status(txid: String) async throws -> WithdrawalStatus {
        let tx = try await index.transaction(txid)
        guard let vout = tx.vout.firstIndex(where: { $0.isWithdrawal }) else { throw TrackerError.notAWithdrawal }
        guard tx.status.confirmed else { return .confirming }
        let outspend = try await index.outspend(txid: txid, vout: vout)
        guard outspend.withdrawalBundleM6id != nil else { return .waitingForBatch }
        // In a batch: ask the enforcer where its vote stands.
        async let proposals = enforcer.withdrawalBundleProposals(slot: slot)
        async let constants = enforcer.bip300Constants()
        async let tip = enforcer.chainTip()
        let c = try await constants
        return WithdrawalStatus.resolve(transactionConfirmed: true, outspend: outspend,
                                        proposals: try await proposals,
                                        inclusionThreshold: c.withdrawalBundleInclusionThreshold,
                                        maxAge: c.withdrawalBundleMaxAge,
                                        mainchainTipHeight: (try? await tip)?.height)
    }
}
