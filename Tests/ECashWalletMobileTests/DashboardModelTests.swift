// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// Card independence, cadence, cache and staleness (`docs/dashboard-plan.md` §3.4, §5).
@MainActor @Suite struct DashboardModelTests {

    /// A source whose answers and failures are set per test, counting calls.
    final class StubSource: DashboardDataSource, @unchecked Sendable {
        var chainResult: Result<ChainSnapshot, DashboardError> = .success(StubSource.chain)
        var marketsResult: Result<MarketBoard, DashboardError> = .success(MarketBoard(quotes: [], wbECX: nil))
        var newsResult: Result<[EcosystemNewsItem], DashboardError> = .success([])
        var releasesResult: Result<ReleaseInfo, DashboardError> = .success(ReleaseInfo(node: nil, wallet: nil))
        var chainCalls = 0
        var marketsCalls = 0

        static let chain = ChainSnapshot(tipHeight: 971_335, blocks: [], transactions24h: 97_726,
                                         mempoolCount: 1_627, mempoolVSize: 324_143)

        func chain(network: DashboardNetwork, now: Int64) async throws -> ChainSnapshot {
            chainCalls += 1
            try Task.checkCancellation()   // like URLSession: a cancelled task throws
            return try chainResult.get()
        }
        func markets() async throws -> MarketBoard {
            marketsCalls += 1
            return try marketsResult.get()
        }
        func news() async throws -> [EcosystemNewsItem] { try newsResult.get() }
        func releases(network: DashboardNetwork) async throws -> ReleaseInfo { try releasesResult.get() }
    }

    final class Clock: @unchecked Sendable {
        var now: Int64 = 1_000
    }

    static func model(_ source: StubSource, cache: MemoryDashboardCache = MemoryDashboardCache(),
                      clock: Clock = Clock()) -> DashboardModel {
        DashboardModel(network: .betanet, source: source, cache: cache, clock: { clock.now })
    }

    @Test func oneFailingSourceLeavesTheOthersLoaded() async {
        let source = StubSource()
        source.marketsResult = .failure(.http(502))
        let model = Self.model(source)
        await model.refresh()
        #expect(model.chain.value?.tipHeight == 971_335)
        #expect(model.chain.display == .ready(stale: false))
        #expect(model.markets.display == .unavailable)
        #expect(model.news.display == .ready(stale: false))
    }

    @Test func aFailedRefreshKeepsTheLastValueMarkedStale() async {
        let source = StubSource()
        let clock = Clock()
        let model = Self.model(source, clock: clock)
        await model.refresh()
        source.chainResult = .failure(.http(503))
        clock.now += DashboardModel.Cadence.chain
        await model.refresh()
        #expect(model.chain.value?.tipHeight == 971_335)   // never blanked to zero
        #expect(model.chain.display == .ready(stale: true))
        #expect(model.chain.updatedAt == 1_000)
    }

    @Test func eachCardKeepsItsOwnCadence() async {
        let source = StubSource()
        let clock = Clock()
        let model = Self.model(source, clock: clock)
        await model.refresh()
        clock.now += DashboardModel.Cadence.markets   // 60 s: markets due, chain (300 s) not
        await model.refresh()
        #expect(source.marketsCalls == 2)
        #expect(source.chainCalls == 1)
    }

    @Test func forceRefreshesEverything() async {
        let source = StubSource()
        let model = Self.model(source)
        await model.refresh()
        await model.refresh(force: true)
        #expect(source.chainCalls == 2)
        #expect(source.marketsCalls == 2)
    }

    @Test func aDownSourceIsRetriedOncePerCadenceNotEveryTick() async {
        let source = StubSource()
        source.chainResult = .failure(.http(500))
        let clock = Clock()
        let model = Self.model(source, clock: clock)
        await model.refresh()
        clock.now += 60
        await model.refresh()
        #expect(source.chainCalls == 1)
    }

    @Test func coldStartShowsTheCacheBeforeAnyFetch() async {
        let cache = MemoryDashboardCache()
        let first = Self.model(StubSource(), cache: cache)
        await first.refresh()
        let second = Self.model(StubSource(), cache: cache)
        #expect(second.chain.value?.tipHeight == 971_335)
        #expect(second.chain.updatedAt == 1_000)
    }

    @Test func cachesAreKeyedByNetwork() async {
        let cache = MemoryDashboardCache()
        await Self.model(StubSource(), cache: cache).refresh()
        #expect(cache.keys.allSatisfy { $0.hasPrefix("betanet.") })
        let mainnet = DashboardNetwork(id: "mainnet", displayName: "Mainnet", explorerURL: "https://x", releasesChannel: "mainnet")
        let flipped = DashboardModel(network: mainnet, source: StubSource(), cache: cache, clock: { 1 })
        #expect(flipped.chain.value == nil)   // betanet's numbers never appear under mainnet
    }

    @Test func aScreenGoingAwayDoesNotCancelTheFetch() async {
        let source = StubSource()
        let clock = Clock()
        let model = Self.model(source, clock: clock)
        await model.refresh()
        clock.now += DashboardModel.Cadence.chain
        // The caller's task is cancelled (a detail screen was pushed over the dashboard)…
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.refresh()
        }
        await task.value
        // …but the fetch still completed and landed, fresh, not stale and not stuck "in flight".
        #expect(source.chainCalls == 2)
        #expect(model.chain.updatedAt == clock.now)
        #expect(model.chain.display == .ready(stale: false))
        #expect(!model.chain.isLoading)
    }

    @Test func sectionDisplay() {
        var section = DashboardSection<Int>()
        #expect(section.display == .loading)
        section.lastAttemptFailed = true
        #expect(section.display == .unavailable)
        section.value = 1
        #expect(section.display == .ready(stale: true))
        #expect(section.isDue(now: 10, cadence: 60))   // never attempted
        section.lastAttemptAt = 0
        #expect(!section.isDue(now: 59, cadence: 60))
        #expect(section.isDue(now: 60, cadence: 60))
    }
}
