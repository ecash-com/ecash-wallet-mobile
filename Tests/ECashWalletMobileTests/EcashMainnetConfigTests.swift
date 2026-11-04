// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// The real eCash fork arrives through the remote config, beside betanet, under the id L2L's catalog
/// stages it as (`ecash-mainnet`; drivechain-frontends `netcatalog/testdata/ecash-mainnet.json`).
/// These check that the entry reaches `.ecashMainnet` and nothing else, that betanet is untouched,
/// and that the fork watcher flips the default only on a tip at or past the entry's fork height.
@Suite(.serialized) struct EcashMainnetConfigTests {

    /// The live drivechain.dev/config entry (2026-10-26), trimmed to what matters, with the
    /// not-yet-published services filled in so the per-network routing is exercised. Mainnet FIRST.
    private static let staged = """
    {
      "schema_version": 1,
      "networks": [
        { "id": "bitcoin", "family": "bitcoin", "display_name": "Bitcoin",
          "backends": [ { "kind": "esplora", "url": "https://esplora.mainnet.drivechain.info" } ] },
        { "id": "ecash", "family": "ecash", "display_name": "eCash",
          "fork_height": 973728, "network_magic": "eca5dcb7",
          "backends": [ { "kind": "esplora", "url": "https://esplora.mainnet.ecash.example" } ],
          "explorer_tx_template": "https://explorer.mainnet.ecash.example/tx/{txid}",
          "services": { "enforcer": { "url": "https://seed.mainnet.ecash.example/enforcer" } } },
        { "id": "betanet", "family": "ecash", "display_name": "Betanet",
          "fork_height": 967680, "replay_lock_time": 499999999,
          "backends": [ { "kind": "esplora", "url": "https://esplora.beta.ecash.ninja" } ],
          "explorer_tx_template": "https://explorer.beta.ecash.ninja/tx/{txid}" }
      ]
    }
    """

    private static func parse(_ json: String) throws -> RemoteEndpointConfig {
        try #require(RemoteEndpointConfig.parse(Data(json.utf8)))
    }

    private static func reset() {
        EcashMainnetLaunch.resetForTesting(offered: false)
        RemoteServiceOverrides.clearEsploraURLForTesting(for: .ecashMainnet)
        RemoteServiceOverrides.clearEsploraURLForTesting(for: .bitcoin)
    }

    // MARK: - Routing

    @Test func theStagedIdReachesTheMainnetCaseAndBetanetKeepsItsOwn() throws {
        let cfg = try Self.parse(Self.staged)
        #expect(cfg.networks.compactMap(\.walletNetwork) == [.bitcoin, .ecashMainnet, .ecashBeta])

        let backends = cfg.resolvedPrimaryBackends()
        #expect(backends.first { $0.network == .ecashMainnet }?.url == "https://esplora.mainnet.ecash.example")
        #expect(backends.first { $0.network == .ecashBeta }?.url == "https://esplora.beta.ecash.ninja")

        let heights = cfg.resolvedForkHeights()
        #expect(heights.first { $0.network == .ecashMainnet }?.height == 973_728)
        #expect(heights.first { $0.network == .ecashBeta }?.height == 967_680)

        let names = cfg.resolvedDisplayNames()
        #expect(names.first { $0.network == .ecashMainnet }?.name == "eCash")
        #expect(names.first { $0.network == .ecashBeta }?.name == "Betanet")

        let enforcers = cfg.resolvedEnforcers()
        #expect(enforcers.first { $0.network == .ecashMainnet }?.url == "https://seed.mainnet.ecash.example/enforcer")
        #expect(enforcers.first { $0.network == .ecashBeta } == nil, "betanet's entry carries no enforcer here")
    }

    /// L2L's catalog fixture staged the fork as `ecash-mainnet`; that spelling still lands on the
    /// same case in case the served config is ever renamed to match.
    @Test func theStagedSpellingStillReachesMainnet() throws {
        let cfg = try Self.parse(Self.staged.replacingOccurrences(of: "\"id\": \"ecash\",", with: "\"id\": \"ecash-mainnet\","))
        #expect(cfg.networks.compactMap(\.walletNetwork) == [.bitcoin, .ecashMainnet, .ecashBeta])
    }

    /// The config id `ecash` is NOT the retired alphanet case, whose persisted rawValue happens to
    /// be the same string. Nothing from the live entry may reach `.ecash`.
    @Test func theLiveIdNeverReachesAlphanet() throws {
        let cfg = try Self.parse(Self.staged)
        #expect(!cfg.networks.compactMap(\.walletNetwork).contains(.ecash))
        #expect(cfg.resolvedPrimaryBackends().first { $0.network == .ecash } == nil)
        #expect(cfg.resolvedForkHeights().first { $0.network == .ecash } == nil)
        #expect(WalletNetwork(rawValue: "ecash") == .ecash, "the rawValue namespace is untouched")
    }

    /// The dashboard block uses the same allow-list, so `"ecash"` there means the same case.
    @Test func theDashboardIdMeansTheSameNetwork() {
        let dash = DashboardNetwork(id: "ecash", displayName: "eCash", explorerURL: "https://e.example",
                                    releasesChannel: "mainnet")
        #expect(dash.walletNetwork == .ecashMainnet)
    }

    /// After the fork the real chain is the default for create and import; before it, betanet. The
    /// picker ORDER never moves and the default is the real fork before and after the fork latch
    /// (Jake, 2026-10-29). Lives here, not in `NetworkSelectorLabelTests`, because this suite owns
    /// the launch-gate state.
    @Test func defaultIsMainnetAndTheOrderNeverMoves() {
        Self.reset()
        EcashMainnetLaunch.resetForTesting(offered: true)
        #expect(WalletNetwork.currentEcash == .ecashMainnet)
        #expect(WalletNetwork.selectable.prefix(2) == [.ecashMainnet, .bitcoin])
        EcashMainnetLaunch.recordObservedTip(height: EcashMainnetLaunch.forkHeight)
        #expect(WalletNetwork.currentEcash == .ecashMainnet)
        #expect(WalletNetwork.selectable.prefix(2) == [.ecashMainnet, .bitcoin])
        Self.reset()
    }

    // MARK: - The fork watcher

    private static func fetcher(tips: [String: String]) -> DashboardFetch {
        { url in
            let host = url.host ?? ""
            guard let body = tips[host] else { return (Data(), 404) }
            return (Data(body.utf8), 200)
        }
    }

    /// No config fetched yet (a first launch, or one whose fetch failed): the watcher still runs,
    /// against the bundled mainnet Esplora — the same host the config publishes — so the default
    /// flip at the fork does not depend on the fetch any more than the offer does (1.4.6 build 44).
    @Test func watchesTheBundledEsploraBeforeTheConfigArrives() async {
        Self.reset()
        #expect(ForkWatch.candidateBases() == ["https://esplora.ecash.ninja"])
        var flipped = await ForkWatch.checkIfNeeded(fetch: Self.fetcher(tips: ["esplora.ecash.ninja": "973727"]))
        #expect(!flipped)
        #expect(WalletNetwork.currentEcash == .ecashMainnet)
        flipped = await ForkWatch.checkIfNeeded(fetch: Self.fetcher(tips: ["esplora.ecash.ninja": "973728"]))
        #expect(flipped)
        #expect(WalletNetwork.currentEcash == .ecashMainnet)
        Self.reset()
    }

    @Test func asksMainnetsOwnEsploraFirstThenBitcoins() async {
        Self.reset()
        EcashMainnetLaunch.resetForTesting(offered: true)
        RemoteServiceOverrides.setEsploraURL("https://esplora.mainnet.ecash.example", for: .ecashMainnet)
        RemoteServiceOverrides.setEsploraURL("https://esplora.mainnet.drivechain.info", for: .bitcoin)
        #expect(ForkWatch.candidateBases() == ["https://esplora.mainnet.ecash.example", "https://esplora.mainnet.drivechain.info"])

        // Mainnet's Esplora is down; Bitcoin's answers, below the height: not yet.
        var flipped = await ForkWatch.checkIfNeeded(fetch: Self.fetcher(tips: ["esplora.mainnet.drivechain.info": "973727\n"]))
        #expect(!flipped)
        #expect(WalletNetwork.currentEcash == .ecashMainnet)

        // The fork block arrives.
        flipped = await ForkWatch.checkIfNeeded(fetch: Self.fetcher(tips: ["esplora.mainnet.drivechain.info": "973728"]))
        #expect(flipped)
        #expect(WalletNetwork.currentEcash == .ecashMainnet)

        // Already the default: the watcher is idle and never asks again.
        flipped = await ForkWatch.checkIfNeeded(fetch: { _ in Issue.record("fetched after the latch"); return (Data(), 500) })
        #expect(!flipped)
        Self.reset()
    }

    @Test func garbageAndErrorsMeanNotYet() async {
        Self.reset()
        EcashMainnetLaunch.resetForTesting(offered: true)
        RemoteServiceOverrides.setEsploraURL("https://esplora.mainnet.ecash.example", for: .ecashMainnet)
        for body in ["", "abc", "-5", "{\"height\":973728}"] {
            let flipped = await ForkWatch.checkIfNeeded(fetch: Self.fetcher(tips: ["esplora.mainnet.ecash.example": body]))
            #expect(!flipped, "body \(body)")
        }
        let failed = await ForkWatch.checkIfNeeded(fetch: { _ in throw DashboardError.http(503) })
        #expect(!failed)
        #expect(WalletNetwork.currentEcash == .ecashMainnet)
        Self.reset()
    }

    /// Betanet is past 973,728 on its OWN chain; its tip must never be what flips the gate.
    @Test func betanetsTipIsNeverConsulted() {
        Self.reset()
        EcashMainnetLaunch.resetForTesting(offered: true)
        RemoteServiceOverrides.setEsploraURL("https://esplora.beta.ecash.ninja", for: .ecashBeta)
        #expect(ForkWatch.candidateBases() == ["https://esplora.ecash.ninja"], "only mainnet's bundled Esplora")
        Self.reset()
    }

    @Test func parsesABareInteger() {
        #expect(ForkWatch.parseTip(Data("973728".utf8)) == 973_728)
        #expect(ForkWatch.parseTip(Data(" 973728\n".utf8)) == 973_728)
        #expect(ForkWatch.parseTip(Data("0".utf8)) == nil)
        #expect(ForkWatch.parseTip(Data("".utf8)) == nil)
    }
}
