// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Everything the dashboard reads, behind one seam so `DashboardModel` is testable without a network.
protocol DashboardDataSource: Sendable {
    func chain(network: DashboardNetwork, now: Int64) async throws -> ChainSnapshot
    func markets() async throws -> MarketBoard
    func news() async throws -> [EcosystemNewsItem]
    func releases(network: DashboardNetwork) async throws -> ReleaseInfo
}

/// The real sources (`docs/dashboard-plan.md` §4).
struct LiveDashboardDataSource: DashboardDataSource {
    var fetch: DashboardFetch = DashboardHTTP.live

    func chain(network: DashboardNetwork, now: Int64) async throws -> ChainSnapshot {
        try await ChainStatsClient(network: network, fetch: fetch).snapshot(now: now)
    }

    func markets() async throws -> MarketBoard {
        try await MarketClient(fetch: fetch).board()
    }

    func news() async throws -> [EcosystemNewsItem] {
        try await EcosystemNewsClient(fetch: fetch).items()
    }

    func releases(network: DashboardNetwork) async throws -> ReleaseInfo {
        try await ReleasesClient(network: network, fetch: fetch).releases()
    }
}
