// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

@Suite struct ReleasesClientTests {
    static let nodeURL = "https://releases.ecash.com/L1-ecash-bitcoin/betanet/latest/release.json"

    @Test func readsBothReleases() async throws {
        let web = FakeDashboardWeb()
        web.on(Self.nodeURL, #"{"version":"31.1.0","commit":"ca64033c137457a3c8ca394186759819a2ab0694","commit_short":"ca64033c1374","files":[]}"#)
        web.on(ReleasesClient.walletRepoAPI, #"{"tag_name":"v1.3.0_build30","name":"v1.3.0_build30","html_url":"https://github.com/ecash-com/ecash-wallet-mobile/releases/tag/v1.3.0_build30","published_at":"2026-10-01T21:00:44Z"}"#)
        let info = try await ReleasesClient(network: .betanet, fetch: web.fetch).releases()
        #expect(info.node == NodeRelease(version: "31.1.0", commitShort: "ca64033c1374", channel: "betanet"))
        #expect(info.wallet?.displayVersion == "1.3.0 (30)")
        #expect(info.wallet?.publishedAt == 1_790_888_444)
    }

    @Test func oneSourceIsEnough() async throws {
        let web = FakeDashboardWeb()
        web.on(Self.nodeURL, #"{"version":"31.1.0","commit":"abcdef0123456789"}"#)
        let info = try await ReleasesClient(network: .betanet, fetch: web.fetch).releases()
        #expect(info.node?.commitShort == "abcdef012345")   // derived when commit_short is absent
        #expect(info.wallet == nil)
    }

    @Test func anUnfamiliarTagIsShownAsIs() {
        #expect(WalletRelease(tag: "nightly-7", url: "", publishedAt: nil).displayVersion == "nightly-7")
        #expect(WalletRelease(tag: "v2.0.0_buildx", url: "", publishedAt: nil).displayVersion == "v2.0.0_buildx")
    }
}
