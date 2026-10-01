// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives the read-only Sidechains screens (`SidechainsScreen`, `SidechainDetailScreen`) for ONE
/// mainchain network: which sidechains are active, what each holds in escrow, what's being voted in,
/// and which withdrawals are in progress. Everything comes from the network's BIP300 enforcer
/// (`EnforcerFetching`); nothing here moves money. Design: `docs/sidechains-ui.md`.
///
/// **Live, cheaply.** `refresh()` first asks for the chain tip, one small call, and refetches
/// everything else only when the tip's block hash has changed. The screen polls it while visible, so
/// the list follows the chain at most one full refetch per block.
///
/// **A failed refresh keeps the last good data** and sets `isStale`, so a flaky connection doesn't
/// blank a screen that was showing something true a minute ago. Deposits (not built yet) must NOT
/// run on stale data; they re-read the treasury themselves (`docs/sidechain-deposits.md` §4c).
@MainActor
@Observable
final class SidechainsViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        /// The last refresh failed. Earlier data, if any, is still shown (`isStale`).
        case failed
    }

    /// An active sidechain plus its escrow. `treasury == nil` means no deposits yet.
    struct Entry: Identifiable, Equatable {
        let sidechain: Sidechain
        let treasury: SidechainTreasury?
        var id: Int { sidechain.slot }
    }

    /// How far a vote has got, against the threshold that applies to it.
    struct VoteProgress: Equatable {
        let votes: Int
        let threshold: Int
        /// 0…1, for a progress bar.
        var fraction: Double { threshold > 0 ? min(1, Double(votes) / Double(threshold)) : 0 }
        var remaining: Int { max(0, threshold - votes) }
    }

    /// A withdrawal batch's position: votes so far, and whether it can still pass before it expires.
    struct WithdrawalProgress: Equatable {
        let votes: VoteProgress
        /// Blocks left before the batch expires unpassed. `nil` when the tip isn't known.
        let blocksUntilExpiry: Int?
        /// Fewest blocks before it could pass: one upvote per block, the best case.
        var blocksToPass: Int { votes.remaining }
        /// False when even an upvote in every remaining block can't reach the threshold in time. The
        /// batch will then fail and those coins get re-batched. Not lost, but not coming soon either.
        var canStillPass: Bool {
            guard let blocksUntilExpiry else { return true }
            return blocksToPass <= blocksUntilExpiry
        }
    }

    let network: WalletNetwork
    let networkDisplayName: String
    let unitLabel: String

    private(set) var state: State = .idle
    private(set) var entries: [Entry] = []
    private(set) var proposals: [SidechainProposal] = []
    private(set) var constants: Bip300Constants?
    private(set) var tip: EnforcerChainTip?
    /// Withdrawal batches per slot, loaded on demand by the detail screen.
    private(set) var bundlesBySlot: [Int: [WithdrawalBundleProposal]] = [:]
    /// Slots whose batch list failed to load on the last try (the detail screen says so).
    private(set) var bundleFailures: Set<Int> = []

    private let enforcer: any EnforcerFetching
    /// Called with each freshly loaded list, so the app can remember slot → name for Activity rows.
    private let onLoaded: @MainActor ([Sidechain]) -> Void
    private var isRefreshing = false

    init(network: WalletNetwork, networkDisplayName: String, unitLabel: String, enforcer: any EnforcerFetching,
         onLoaded: @escaping @MainActor ([Sidechain]) -> Void = { _ in }) {
        self.network = network
        self.networkDisplayName = networkDisplayName
        self.unitLabel = unitLabel
        self.enforcer = enforcer
        self.onLoaded = onLoaded
    }

    /// True once something has been shown. Distinguishes "first load failed" (show an error)
    /// from "refresh failed" (keep the list, show a quiet note).
    var hasData: Bool { tip != nil }
    var isStale: Bool { state == .failed && hasData }
    var isFirstLoad: Bool { !hasData && (state == .idle || state == .loading) }

    func entry(slot: Int) -> Entry? { entries.first { $0.sidechain.slot == slot } }

    /// Total escrow across every active sidechain on this network.
    var totalEscrowSats: Int64 { entries.reduce(Int64(0)) { $0 + ($1.treasury?.valueSats ?? 0) } }

    // MARK: - Loading

    /// Refresh if the chain has moved since the last load (or nothing is loaded yet). The screen
    /// calls this on appear and on a timer; it costs one small request when nothing changed.
    func refresh() async { await reload(force: false) }

    /// Refetch everything regardless of the tip (pull-to-refresh).
    func forceRefresh() async { await reload(force: true) }

    private func reload(force: Bool) async {
        // One refresh at a time. A poll that lands during a pull-to-refresh is simply dropped.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if !hasData { state = .loading }
        do {
            let newTip = try await enforcer.chainTip()
            if !force, state == .loaded, newTip.blockHash == tip?.blockHash { return }

            let fetchedConstants = try await enforcer.bip300Constants()
            let sidechains = try await enforcer.sidechains()
            let fetchedProposals = try await enforcer.sidechainProposals()
            let treasuries = try await fetchTreasuries(slots: sidechains.map(\.slot))

            // Publish as one snapshot so the screen never shows a new list with old escrow values.
            constants = fetchedConstants
            entries = sidechains.map { Entry(sidechain: $0, treasury: treasuries[$0.slot] ?? nil) }
            proposals = fetchedProposals
            tip = newTip
            // Batches belong to the old tip; the detail screen reloads the ones it shows.
            bundlesBySlot = [:]
            bundleFailures = []
            state = .loaded
            onLoaded(sidechains)
        } catch {
            state = .failed
        }
    }

    /// Every slot's treasury, fetched concurrently. One failure fails the whole refresh: a list
    /// where some escrow values are current and others missing would look complete and not be.
    private func fetchTreasuries(slots: [Int]) async throws -> [Int: SidechainTreasury?] {
        let enforcer = self.enforcer
        return try await withThrowingTaskGroup(of: (Int, SidechainTreasury?).self) { group in
            for slot in slots {
                group.addTask { (slot, try await enforcer.treasury(slot: slot)) }
            }
            var result: [Int: SidechainTreasury?] = [:]
            for try await (slot, treasury) in group { result[slot] = treasury }
            return result
        }
    }

    /// Load (or reload) the withdrawal batches for one slot. Called by the detail screen.
    func loadBundles(slot: Int) async {
        do {
            bundlesBySlot[slot] = try await enforcer.withdrawalBundleProposals(slot: slot)
            bundleFailures.remove(slot)
        } catch {
            bundleFailures.insert(slot)
        }
    }

    // MARK: - Derived numbers (all from the enforcer's constants, never hardcoded)

    /// Votes needed to activate `proposal`. A proposal for a slot that's already active replaces a
    /// sidechain, which BIP300 treats as a "used" slot with the higher threshold; otherwise the
    /// unused-slot threshold applies. A slot that held a sidechain in the past and is empty now is
    /// also "used", and the enforcer doesn't report that, so an empty slot's bar may run optimistic.
    func activationProgress(for proposal: SidechainProposal) -> VoteProgress? {
        guard let constants else { return nil }
        let replacesActive = entries.contains { $0.sidechain.slot == proposal.slot }
        let threshold = replacesActive ? constants.usedSlotActivationThreshold : constants.unusedSlotActivationThreshold
        guard threshold > 0 else { return nil }
        return VoteProgress(votes: proposal.voteCount, threshold: threshold)
    }

    func withdrawalProgress(for bundle: WithdrawalBundleProposal) -> WithdrawalProgress? {
        guard let constants, constants.withdrawalBundleInclusionThreshold > 0 else { return nil }
        let votes = VoteProgress(votes: bundle.voteCount, threshold: constants.withdrawalBundleInclusionThreshold)
        let untilExpiry = tip.map { max(0, constants.withdrawalBundleMaxAge - ($0.height - bundle.proposalHeight)) }
        return WithdrawalProgress(votes: votes, blocksUntilExpiry: untilExpiry)
    }

    /// The best-case wait before a withdrawal from this network's sidechains can pay out: a new
    /// batch passes only with MORE than the inclusion threshold of upvotes (`votes > threshold` in the
    /// enforcer, validator/task/mod.rs), so at least threshold + 1 consecutive blocks. Drives the
    /// "coming back takes about…" copy on the detail screen, the deposit review and the withdrawal flow.
    var minimumWithdrawalBlocks: Int? {
        guard let t = constants?.withdrawalBundleInclusionThreshold, t > 0 else { return nil }
        return t + 1
    }

    /// How long a withdrawal batch has to pass before it expires and goes back in line.
    var withdrawalExpiryBlocks: Int? {
        guard let age = constants?.withdrawalBundleMaxAge, age > 0 else { return nil }
        return age
    }
}
