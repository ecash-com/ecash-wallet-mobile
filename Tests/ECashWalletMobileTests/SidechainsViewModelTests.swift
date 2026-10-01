// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// `SidechainsViewModel` against a mock enforcer: loading, refetch-on-new-block, stale-on-failure,
/// and the vote/withdrawal arithmetic. No network.
@MainActor
@Suite struct SidechainsViewModelTests {

    /// A scriptable enforcer. Values mirror live betanet (2026-09-29) so the numbers read true.
    final class MockEnforcer: EnforcerFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var _tip = EnforcerChainTip(height: 970_659, blockHash: "hash-a")
        private var _failing = false
        private var _sidechainsCalls = 0
        private var _sidechains: [Sidechain] = [
            Sidechain(slot: 9, title: "Thunder", description: "Fraud proofs", voteCount: 1009,
                      proposalHeight: 967_989, activationHeight: 968_998),
            Sidechain(slot: 98, title: "zSide", description: "Private transactions", voteCount: 1009,
                      proposalHeight: 967_989, activationHeight: 968_998),
        ]
        var treasuries: [Int: SidechainTreasury] = [
            9: SidechainTreasury(txid: String(repeating: "f8", count: 32), vout: 0,
                                 valueSats: 519_790_000, sequenceNumber: 8),
        ]
        var proposals: [SidechainProposal] = [
            SidechainProposal(slot: 8, title: "Solana", description: "A Solana sidechain",
                              voteCount: 808, proposalHeight: 969_851, proposalAge: 808),
        ]
        var bundles: [Int: [WithdrawalBundleProposal]] = [
            9: [WithdrawalBundleProposal(m6id: "aa769fec" + String(repeating: "0", count: 56),
                                         voteCount: 121, proposalHeight: 970_438)],
        ]
        let constants = Bip300Constants(withdrawalBundleMaxAge: 26_300, withdrawalBundleInclusionThreshold: 13_150,
                                        usedSlotActivationThreshold: 13_150, unusedSlotActivationThreshold: 1_008,
                                        activationHeight: 967_680)

        var tip: EnforcerChainTip {
            get { lock.withLock { _tip } }
            set { lock.withLock { _tip = newValue } }
        }
        var failing: Bool {
            get { lock.withLock { _failing } }
            set { lock.withLock { _failing = newValue } }
        }
        var sidechainsList: [Sidechain] {
            get { lock.withLock { _sidechains } }
            set { lock.withLock { _sidechains = newValue } }
        }
        var sidechainsCalls: Int { lock.withLock { _sidechainsCalls } }

        private func check() throws { if failing { throw EnforcerError.network } }

        func chainTip() async throws -> EnforcerChainTip { try check(); return tip }
        func bip300Constants() async throws -> Bip300Constants { try check(); return constants }
        func sidechains() async throws -> [Sidechain] {
            try check()
            return lock.withLock { _sidechainsCalls += 1; return _sidechains }
        }
        func treasury(slot: Int) async throws -> SidechainTreasury? { try check(); return treasuries[slot] }
        func sidechainProposals() async throws -> [SidechainProposal] { try check(); return proposals }
        func withdrawalBundleProposals(slot: Int) async throws -> [WithdrawalBundleProposal] {
            try check(); return bundles[slot] ?? []
        }
    }

    private func makeVM(_ enforcer: MockEnforcer) -> SidechainsViewModel {
        SidechainsViewModel(network: .ecashBeta, networkDisplayName: "Betanet", unitLabel: "ECX", enforcer: enforcer)
    }

    // MARK: - Loading

    @Test func startsInFirstLoad() {
        let vm = makeVM(MockEnforcer())
        #expect(vm.isFirstLoad)
        #expect(!vm.hasData)
        #expect(!vm.isStale)
    }

    @Test func loadsSidechainsWithTheirEscrow() async {
        let vm = makeVM(MockEnforcer())
        await vm.refresh()

        #expect(vm.state == .loaded)
        #expect(vm.entries.map(\.sidechain.slot) == [9, 98])
        #expect(vm.entry(slot: 9)?.treasury?.valueSats == 519_790_000)
        #expect(vm.entry(slot: 98)?.treasury == nil)          // active, never deposited to
        #expect(vm.totalEscrowSats == 519_790_000)
        #expect(vm.proposals.map(\.title) == ["Solana"])
        #expect(vm.tip?.height == 970_659)
        #expect(!vm.isFirstLoad)
    }

    @Test func sameBlockSkipsTheRefetch() async {
        let enforcer = MockEnforcer()
        let vm = makeVM(enforcer)
        await vm.refresh()
        await vm.refresh()
        await vm.refresh()
        // Only the tip was asked for after the first load: the poll is one small request per tick.
        #expect(enforcer.sidechainsCalls == 1)
    }

    @Test func newBlockRefetches() async {
        let enforcer = MockEnforcer()
        let vm = makeVM(enforcer)
        await vm.refresh()

        enforcer.tip = EnforcerChainTip(height: 970_660, blockHash: "hash-b")
        enforcer.sidechainsList.append(Sidechain(slot: 8, title: "Solana", description: "", voteCount: 1008,
                                                 proposalHeight: 969_851, activationHeight: 970_660))
        await vm.refresh()

        #expect(enforcer.sidechainsCalls == 2)
        #expect(vm.entries.map(\.sidechain.slot) == [9, 98, 8])
        #expect(vm.tip?.blockHash == "hash-b")
    }

    @Test func forceRefreshRefetchesOnTheSameBlock() async {
        let enforcer = MockEnforcer()
        let vm = makeVM(enforcer)
        await vm.refresh()
        await vm.forceRefresh()
        #expect(enforcer.sidechainsCalls == 2)
    }

    @Test func failedRefreshKeepsTheLastGoodDataAsStale() async {
        let enforcer = MockEnforcer()
        let vm = makeVM(enforcer)
        await vm.refresh()

        enforcer.failing = true
        await vm.forceRefresh()

        #expect(vm.state == .failed)
        #expect(vm.isStale)
        #expect(vm.entries.count == 2)                          // still showing what was true
        #expect(vm.entry(slot: 9)?.treasury?.valueSats == 519_790_000)
    }

    @Test func recoversAfterAFailureEvenOnTheSameBlock() async {
        let enforcer = MockEnforcer()
        let vm = makeVM(enforcer)
        await vm.refresh()
        enforcer.failing = true
        await vm.refresh()
        enforcer.failing = false
        await vm.refresh()   // tip unchanged, but the last attempt failed, so it must refetch

        #expect(vm.state == .loaded)
        #expect(!vm.isStale)
        #expect(enforcer.sidechainsCalls == 2)
    }

    @Test func firstLoadFailureHasNoData() async {
        let enforcer = MockEnforcer()
        enforcer.failing = true
        let vm = makeVM(enforcer)
        await vm.refresh()

        #expect(vm.state == .failed)
        #expect(!vm.hasData)
        #expect(!vm.isStale)       // nothing to be stale: the screen shows the error state
        #expect(!vm.isFirstLoad)   // …and not the spinner
    }

    @Test func oneTreasuryFailureFailsTheWholeRefresh() async {
        // A list where some escrow values are fresh and others missing would look complete and not be.
        final class FlakyTreasury: EnforcerFetching, @unchecked Sendable {
            let base = MockEnforcer()
            func chainTip() async throws -> EnforcerChainTip { try await base.chainTip() }
            func bip300Constants() async throws -> Bip300Constants { try await base.bip300Constants() }
            func sidechains() async throws -> [Sidechain] { try await base.sidechains() }
            func treasury(slot: Int) async throws -> SidechainTreasury? {
                if slot == 98 { throw EnforcerError.network }
                return try await base.treasury(slot: slot)
            }
            func sidechainProposals() async throws -> [SidechainProposal] { try await base.sidechainProposals() }
            func withdrawalBundleProposals(slot: Int) async throws -> [WithdrawalBundleProposal] { [] }
        }
        let vm = SidechainsViewModel(network: .ecashBeta, networkDisplayName: "Betanet", unitLabel: "ECX",
                                     enforcer: FlakyTreasury())
        await vm.refresh()
        #expect(vm.state == .failed)
        #expect(vm.entries.isEmpty)
    }

    @Test func reportsEachLoadedListForNaming() async {
        final class Box: @unchecked Sendable { var lists: [[Sidechain]] = [] }
        let box = Box()
        let enforcer = MockEnforcer()
        let vm = SidechainsViewModel(network: .ecashBeta, networkDisplayName: "Betanet", unitLabel: "ECX",
                                     enforcer: enforcer, onLoaded: { box.lists.append($0) })
        await vm.refresh()
        await vm.refresh()                 // same block: nothing new to report
        enforcer.failing = true
        await vm.forceRefresh()            // failure: nothing to report
        #expect(box.lists.count == 1)
        #expect(box.lists.first?.map(\.title) == ["Thunder", "zSide"])
    }

    // MARK: - Withdrawal batches

    @Test func loadsBundlesForOneSlot() async {
        let vm = makeVM(MockEnforcer())
        await vm.refresh()
        await vm.loadBundles(slot: 9)
        await vm.loadBundles(slot: 98)

        #expect(vm.bundlesBySlot[9]?.count == 1)
        #expect(vm.bundlesBySlot[98]?.isEmpty == true)   // loaded, and empty, which is not "unknown"
        #expect(vm.bundlesBySlot[4] == nil)              // never asked
    }

    @Test func bundleFailureIsTrackedPerSlot() async {
        let enforcer = MockEnforcer()
        let vm = makeVM(enforcer)
        await vm.refresh()
        enforcer.failing = true
        await vm.loadBundles(slot: 9)
        #expect(vm.bundleFailures == [9])

        enforcer.failing = false
        await vm.loadBundles(slot: 9)
        #expect(vm.bundleFailures.isEmpty)
    }

    @Test func withdrawalProgressUsesTheChainsConstants() async throws {
        let vm = makeVM(MockEnforcer())
        await vm.refresh()
        await vm.loadBundles(slot: 9)
        let bundle = try #require(vm.bundlesBySlot[9]?.first)
        let progress = try #require(vm.withdrawalProgress(for: bundle))

        #expect(progress.votes.votes == 121)
        #expect(progress.votes.threshold == 13_150)
        #expect(progress.blocksToPass == 13_029)
        // Proposed at 970,438, tip 970,659 → 221 blocks old, of 26,300 allowed.
        #expect(progress.blocksUntilExpiry == 26_079)
        #expect(progress.canStillPass)
    }

    @Test func batchThatCantReachThresholdInTimeSaysSo() {
        let votes = SidechainsViewModel.VoteProgress(votes: 100, threshold: 13_150)
        let progress = SidechainsViewModel.WithdrawalProgress(votes: votes, blocksUntilExpiry: 5_000)
        #expect(!progress.canStillPass)
    }

    @Test func minimumWithdrawalWaitIsTheInclusionThreshold() async {
        let vm = makeVM(MockEnforcer())
        #expect(vm.minimumWithdrawalBlocks == nil)       // unknown until loaded, never a guess
        await vm.refresh()
        #expect(vm.minimumWithdrawalBlocks == 13_151)   // votes must EXCEED the 13,150 threshold
        #expect(ApproximateDuration(blocks: 13_150) == .months(3))
    }

    // MARK: - Proposals

    @Test func proposalForAnEmptySlotUsesTheUnusedThreshold() async throws {
        let vm = makeVM(MockEnforcer())
        await vm.refresh()
        let solana = try #require(vm.proposals.first)
        let progress = try #require(vm.activationProgress(for: solana))
        #expect(progress.threshold == 1_008)
        #expect(progress.votes == 808)
        #expect(abs(progress.fraction - 808.0 / 1008.0) < 0.0001)
    }

    @Test func proposalReplacingAnActiveSidechainUsesTheUsedThreshold() async throws {
        let enforcer = MockEnforcer()
        enforcer.proposals = [SidechainProposal(slot: 9, title: "Thunder 2", description: "", voteCount: 50,
                                                proposalHeight: 970_600, proposalAge: 59)]
        let vm = makeVM(enforcer)
        await vm.refresh()
        let replacement = try #require(vm.proposals.first)
        let progress = try #require(vm.activationProgress(for: replacement))
        #expect(progress.threshold == 13_150)
    }

    @Test func noThresholdBeforeLoad() {
        let vm = makeVM(MockEnforcer())
        let p = SidechainProposal(slot: 8, title: "x", description: "", voteCount: 1, proposalHeight: 1, proposalAge: 1)
        #expect(vm.activationProgress(for: p) == nil)
    }

    @Test func voteProgressClamps() {
        #expect(SidechainsViewModel.VoteProgress(votes: 2_000, threshold: 1_008).fraction == 1)
        #expect(SidechainsViewModel.VoteProgress(votes: 2_000, threshold: 1_008).remaining == 0)
        #expect(SidechainsViewModel.VoteProgress(votes: 5, threshold: 0).fraction == 0)
    }

    // MARK: - Durations

    @Test func approximateDurations() {
        #expect(ApproximateDuration(blocks: 0) == .minutes(1))
        #expect(ApproximateDuration(blocks: 3) == .minutes(30))
        #expect(ApproximateDuration(blocks: 6) == .hours(1))
        #expect(ApproximateDuration(blocks: 144) == .hours(24))
        #expect(ApproximateDuration(blocks: 288) == .days(2))
        #expect(ApproximateDuration(blocks: 1_008) == .days(7))
        #expect(ApproximateDuration(blocks: 2_016) == .weeks(2))
        #expect(ApproximateDuration(blocks: 13_029) == .months(3))
        #expect(ApproximateDuration(blocks: 26_300) == .months(6))
    }

    @Test func shortBatchId() {
        #expect(WithdrawalBatchRow.shortId("aa769fec72ddc7e59fb6dc480d62ba19236804598d053b6c50522cae30b0ced4")
                == "aa769fec…ced4")
        #expect(WithdrawalBatchRow.shortId("abc") == "abc")
    }
}

/// Slot → name persistence for Activity labels. Serialized: it writes UserDefaults.
@Suite(.serialized) struct SidechainNameCacheTests {
    @Test func roundTripsPerNetwork() {
        SidechainNameCache.clearAll()
        defer { SidechainNameCache.clearAll() }
        SidechainNameCache.save([9: "Thunder", 0: "Zero", 255: "Coinshift"], for: .ecashBeta)
        #expect(SidechainNameCache.load(for: .ecashBeta) == [9: "Thunder", 0: "Zero", 255: "Coinshift"])
        #expect(SidechainNameCache.load(for: .ecash).isEmpty)   // networks don't share names
    }
}
