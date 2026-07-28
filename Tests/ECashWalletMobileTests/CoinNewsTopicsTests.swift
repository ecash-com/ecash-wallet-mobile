// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// Topic management + per-network CoinNews behavior: feed filtering, optimistic topics, the local
/// per-network subscription store, the topic manager view model, network availability, and the
/// network-scoped seeded client.
@MainActor
@Suite struct CoinNewsTopicsTests {

    // MARK: - Fixtures

    private struct FakeFetcher: CoinNewsFetching {
        let topicsList: [CoinNewsTopic]
        let items: [CoinNewsItem]
        func topics() async throws -> [CoinNewsTopic] { topicsList }
        func frontPage(limit: Int) async throws -> [CoinNewsItem] { items }
        func newFeed(limit: Int) async throws -> [CoinNewsItem] { items }
        func item(id: String) async throws -> CoinNewsItem? { items.first { $0.id == id } }
        func thread(rootId: String) async throws -> [CoinNewsComment] { [] }
    }

    private func item(_ id: String, _ topicHex: String) -> CoinNewsItem {
        CoinNewsItem(id: id, topicHex: topicHex, headline: "Headline \(id)")
    }
    private func topic(_ hex: String) -> CoinNewsTopic {
        CoinNewsTopic(topicHex: hex, name: "Topic \(hex)", retentionDays: 0)
    }

    /// A cleared, isolated pending store (host-only test domain) so optimistic content from one test
    /// doesn't bleed into another.
    private func freshPendingStore() -> PendingCoinNewsStore {
        let suite = "test.pending.coinnews"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return PendingCoinNewsStore(defaults: d)
    }

    private func loadedFeed() async -> CoinNewsViewModel {
        let vm = CoinNewsViewModel(
            network: .signet,
            fetcher: FakeFetcher(
                topicsList: [topic("aaaa"), topic("bbbb")],
                items: [item("1", "aaaa"), item("2", "bbbb"), item("3", "aaaa")]),
            pending: freshPendingStore())
        await vm.load()
        return vm
    }

    // MARK: - Feed filtering

    @Test func feedFiltersByTopicAndFollowed() async {
        let vm = await loadedFeed()
        #expect(vm.visibleItems.count == 3)              // .all

        vm.feedFilter = .topic("aaaa")
        #expect(vm.visibleItems.count == 2)              // only aaaa items
        #expect(vm.activeTopicName == "Topic aaaa")      // resolves the display name

        vm.followed = ["bbbb"]
        vm.feedFilter = .followed
        #expect(vm.visibleItems.count == 1)              // only the followed topic's item
        #expect(vm.visibleItems.first?.topicHex == "bbbb")

        vm.feedFilter = .all
        #expect(vm.activeTopicName == nil)
    }

    @Test func addPendingTopicIsOptimisticAndIdempotent() async {
        let vm = await loadedFeed()
        let before = vm.topics.count
        vm.addPendingTopic(CoinNewsTopic(topicHex: "cccc", name: "Fresh", retentionDays: 5))
        #expect(vm.topics.count == before + 1)
        #expect(vm.topicName(for: "cccc") == "Fresh")
        #expect(vm.pendingTopicHexes.contains("cccc"))
        // Re-adding the same id is a no-op (won't duplicate when the indexer also returns it).
        vm.addPendingTopic(CoinNewsTopic(topicHex: "cccc", name: "Dup", retentionDays: 9))
        #expect(vm.topics.count == before + 1)
    }

    // MARK: - Subscription store (per network)

    @Test func subscriptionsAreIsolatedPerNetwork() {
        let store = TopicSubscriptionStore(defaults: .standard)
        // Normalize (tests share .standard); use unique ids that won't collide with real data.
        store.unfollow("ts-aaaa", on: .signet)
        store.unfollow("ts-aaaa", on: .bitcoin)

        store.follow("ts-aaaa", on: .signet)
        #expect(store.isFollowed("ts-aaaa", on: .signet))
        #expect(!store.isFollowed("ts-aaaa", on: .bitcoin))   // a different network is unaffected

        let after = store.toggle("ts-aaaa", on: .signet)        // toggle off
        #expect(!after.contains("ts-aaaa"))
        #expect(!store.isFollowed("ts-aaaa", on: .signet))
    }

    // MARK: - Topic manager view model

    @Test func topicsViewModelFollowsAndFiltersTheFeed() async {
        let feed = await loadedFeed()
        let store = TopicSubscriptionStore(defaults: .standard)
        store.unfollow("aaaa", on: .signet)   // normalize

        let vm = TopicsViewModel(feed: feed, subscriptions: store, makeCreateTopic: { _ in nil })
        let t = feed.topics.first { $0.topicHex == "aaaa" }!

        #expect(!vm.isFollowed(t))
        vm.toggleFollow(t)
        #expect(vm.isFollowed(t))
        #expect(feed.followed.contains("aaaa"))           // mirrored into the feed for .followed

        vm.showTopic(t)
        #expect(feed.feedFilter == .topic("aaaa"))
        #expect(feed.visibleItems.count == 2)
        #expect(vm.isShowing(t))

        vm.showAll()
        #expect(feed.feedFilter == .all)
        #expect(vm.isShowingAll)

        store.unfollow("aaaa", on: .signet)   // cleanup
    }

    // MARK: - Network availability (code-level capability)

    @Test func coinNewsOffOnBitcoinOnly() {
        #expect(!CoinNewsAvailability.isAvailable(on: .bitcoin))
        #expect(CoinNewsAvailability.isAvailable(on: .signet))
    }

    // MARK: - Per-network endpoint + empty fallback

    /// Asserts the BUNDLED mapping, not `publicEndpoint` — the latter lets a remote overlay win, and
    /// overlays live in process-global UserDefaults that another suite may be writing concurrently.
    /// Testing through it made this fail at random with whatever URL that suite had just set.
    @Test func publicEndpointRegistryIsPerNetwork() {
        #expect(CoinNewsEndpointRegistry.bundledEndpoint(for: .signet) != nil)   // hosted indexer
        #expect(CoinNewsEndpointRegistry.bundledEndpoint(for: .bitcoin) == nil)  // none yet
    }

    @Test func emptyClientReturnsNothing() async throws {
        let c = EmptyCoinNewsClient()
        #expect(try await c.topics().isEmpty)
        #expect(try await c.frontPage(limit: 50).isEmpty)
        #expect(try await c.newFeed(limit: 50).isEmpty)
    }

    // MARK: - Pending (optimistic) store

    private func pendingStore(ttl: Int64 = 24 * 60 * 60) -> PendingCoinNewsStore {
        let suite = "test.pending.coinnews.store"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return PendingCoinNewsStore(defaults: d, ttlSeconds: ttl)
    }

    @Test func pendingStoreReconcilesByContentAndHex() {
        let store = pendingStore()
        store.addItem(CoinNewsItem(id: "pending:tx1", topicHex: "aaaa", headline: "Hello", body: "world"), on: .signet)
        store.addTopic(CoinNewsTopic(topicHex: "a5a9412e", name: "Nostr Stuff", retentionDays: 7), on: .signet)
        #expect(store.items(on: .signet).count == 1)
        #expect(store.topics(on: .signet).count == 1)

        // Indexer returns the same story (different id) + the topic → both reconciled away.
        store.reconcileItems(fetched: [CoinNewsItem(id: "abc", topicHex: "aaaa", headline: "Hello", body: "world")], on: .signet)
        store.reconcileTopics(fetchedHexes: ["a5a9412e"], on: .signet)
        #expect(store.items(on: .signet).isEmpty)
        #expect(store.topics(on: .signet).isEmpty)
    }

    @Test func pendingStoreExpiresViaTTL() {
        let store = pendingStore(ttl: -1)   // already past expiry
        store.addItem(CoinNewsItem(id: "pending:tx2", topicHex: "aaaa", headline: "Stale"), on: .signet)
        store.reconcileItems(fetched: [], on: .signet)   // no content match, but TTL drops it
        #expect(store.items(on: .signet).isEmpty)
    }

    @Test func pendingStoreIsPerNetwork() {
        let store = pendingStore()
        store.addTopic(CoinNewsTopic(topicHex: "dddd", name: "Sig", retentionDays: 0), on: .signet)
        #expect(store.topics(on: .signet).count == 1)
        #expect(store.topics(on: .bitcoin).isEmpty)   // isolated per network
    }
}
