// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Reads the Releases card. The node's `latest/release.json` is the release site's own machine
/// format; the wallet's is GitHub's unauthenticated API (60 requests/hour per IP — the card refreshes
/// hourly, so a phone stays far below it).
struct ReleasesClient: Sendable {
    let network: DashboardNetwork
    let fetch: DashboardFetch
    static let walletRepoAPI = "https://api.github.com/repos/ecash-com/ecash-wallet-mobile/releases/latest"

    func releases() async throws -> ReleaseInfo {
        async let node = try? nodeRelease()
        async let wallet = try? walletRelease()
        let info = ReleaseInfo(node: await node, wallet: await wallet)
        if info.node == nil && info.wallet == nil { throw DashboardError.malformed("releases: both failed") }
        return info
    }

    func nodeRelease() async throws -> NodeRelease {
        let channel = network.releasesChannel
        let url = try DashboardHTTP.url("https://releases.ecash.com", "/L1-ecash-bitcoin/\(channel)/latest/release.json")
        let wire = try await DashboardHTTP.decode(NodeReleaseJSON.self, from: url, using: fetch, route: "release.json")
        let short = wire.commitShort ?? String((wire.commit ?? "").prefix(12))
        return NodeRelease(version: wire.version, commitShort: short, channel: channel)
    }

    func walletRelease() async throws -> WalletRelease {
        guard let url = URL(string: Self.walletRepoAPI) else { throw DashboardError.malformed("github url") }
        let wire = try await DashboardHTTP.decode(GitHubRelease.self, from: url, using: fetch, route: "github release")
        var published: Int64? = nil
        if let text = wire.publishedAt, let date = ISO8601DateFormatter().date(from: text) {
            published = Int64(date.timeIntervalSince1970)
        }
        return WalletRelease(tag: wire.tagName, url: wire.htmlURL, publishedAt: published)
    }
}

struct NodeReleaseJSON: Decodable {
    let version: String
    let commit: String?
    let commitShort: String?

    enum CodingKeys: String, CodingKey {
        case version, commit
        case commitShort = "commit_short"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}
