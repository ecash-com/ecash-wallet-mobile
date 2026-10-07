// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse

/// Drives the Dashboard tab: one independent section per card, each with its own refresh cadence,
/// cache and failure state (`docs/dashboard-plan.md` §3.4, §5).
///
/// One instance per dashboard network. When the remote config flips the network (betanet → mainnet at
/// the fork), `AppState` replaces the model rather than mutating this one, so nothing from the old
/// network can survive into the new one.
@MainActor
@Observable
final class DashboardModel {
    let network: DashboardNetwork
    private(set) var chain = DashboardSection<ChainSnapshot>()
    private(set) var markets = DashboardSection<MarketBoard>()
    private(set) var news = DashboardSection<[EcosystemNewsItem]>()
    private(set) var releases = DashboardSection<ReleaseInfo>()

    /// Seconds between refreshes per card. The chain and its explorer move every block; prices every
    /// minute; the news feed declares a 15-minute `ttl`; releases are rare.
    enum Cadence {
        static let chain: Int64 = 300
        static let markets: Int64 = 60
        static let news: Int64 = 900
        static let releases: Int64 = 3_600
    }

    @ObservationIgnored private let source: DashboardDataSource
    @ObservationIgnored private let cache: DashboardCaching
    @ObservationIgnored private let clock: @Sendable () -> Int64

    init(network: DashboardNetwork,
         source: DashboardDataSource = LiveDashboardDataSource(),
         cache: DashboardCaching = FileDashboardCache(),
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.network = network
        self.source = source
        self.cache = cache
        self.clock = clock
        // Last good values first, so the screen opens on numbers rather than skeletons.
        if let hit = cache.load(ChainSnapshot.self, key: key("chain")) { chain.value = hit.value; chain.updatedAt = hit.at }
        if let hit = cache.load(MarketBoard.self, key: key("markets")) { markets.value = hit.value; markets.updatedAt = hit.at }
        if let hit = cache.load([EcosystemNewsItem].self, key: key("news")) { news.value = hit.value; news.updatedAt = hit.at }
        if let hit = cache.load(ReleaseInfo.self, key: key("releases")) { releases.value = hit.value; releases.updatedAt = hit.at }
    }

    /// Refresh every card that's due (all of them when `force` — pull to refresh). The cards load
    /// concurrently and independently: a slow or failing source never holds up the others.
    ///
    /// The fetches run in their own task, so a caller going away doesn't cancel them: pushing a detail
    /// screen cancels the root screen's `.task`, and cancelling a fetch half-way would leave the card
    /// marked "in flight" while the newly shown screen skipped refreshing because of it. The work
    /// finishes and lands in the model whoever is still watching.
    func refresh(force: Bool = false) async {
        let work = Task { await self.refreshDueSections(force: force) }
        await work.value
    }

    private func refreshDueSections(force: Bool) async {
        let now = clock()
        async let chainDone: Void = refreshChain(force: force, now: now)
        async let marketsDone: Void = refreshMarkets(force: force, now: now)
        async let newsDone: Void = refreshNews(force: force, now: now)
        async let releasesDone: Void = refreshReleases(force: force, now: now)
        _ = await (chainDone, marketsDone, newsDone, releasesDone)
    }

    private func refreshChain(force: Bool, now: Int64) async {
        let source = self.source, network = self.network
        await load(get: { self.chain }, set: { self.chain = $0 }, cadence: Cadence.chain, force: force,
                   now: now, key: "chain") { try await source.chain(network: network, now: now) }
    }

    private func refreshMarkets(force: Bool, now: Int64) async {
        let source = self.source
        await load(get: { self.markets }, set: { self.markets = $0 }, cadence: Cadence.markets, force: force,
                   now: now, key: "markets") { try await source.markets() }
    }

    private func refreshNews(force: Bool, now: Int64) async {
        let source = self.source
        await load(get: { self.news }, set: { self.news = $0 }, cadence: Cadence.news, force: force,
                   now: now, key: "news") { try await source.news() }
    }

    private func refreshReleases(force: Bool, now: Int64) async {
        let source = self.source, network = self.network
        await load(get: { self.releases }, set: { self.releases = $0 }, cadence: Cadence.releases, force: force,
                   now: now, key: "releases") { try await source.releases(network: network) }
    }

    /// One card's refresh: skip unless due (or forced) and not already in flight; keep the old value
    /// on failure, mark it stale; cache on success.
    private func load<T: Codable & Equatable & Sendable>(
        get: () -> DashboardSection<T>, set: (DashboardSection<T>) -> Void,
        cadence: Int64, force: Bool, now: Int64, key name: String,
        fetch: @Sendable () async throws -> T
    ) async {
        var section = get()
        guard !section.isLoading, force || section.isDue(now: now, cadence: cadence) else { return }
        let previousAttempt = section.lastAttemptAt
        section.isLoading = true
        section.lastAttemptAt = now
        set(section)
        do {
            let value = try await fetch()
            let at = clock()
            section = get()
            section.value = value
            section.updatedAt = at
            section.lastAttemptFailed = false
            section.isLoading = false
            set(section)
            cache.save(value, at: at, key: key(name))
        } catch {
            section = get()
            section.isLoading = false
            if error is CancellationError || Task.isCancelled {
                // Not a failure: the fetch was cancelled (`refresh` detaches its work so a screen going
                // away shouldn't do this — defensive). Don't mark the card stale, and don't count the
                // attempt, so the next tick retries instead of waiting out the cadence.
                section.lastAttemptAt = previousAttempt
            } else {
                section.lastAttemptFailed = true
            }
            set(section)
        }
    }

    private func key(_ section: String) -> String { "\(network.id).\(section)" }
}
