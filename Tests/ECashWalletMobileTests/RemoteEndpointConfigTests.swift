// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// Parsing + resolution of the remote network config (https://drivechain.dev/config), and the
/// fail-safe fetch service. All pure/injected — no real network. Payload `networks` is an ARRAY,
/// mapped to `WalletNetwork` by `family` (the eCash entry's id is `drynet2`, family `ecash`).
///
/// `.serialized`: several tests mutate process-global `UserDefaults.standard` (via
/// `RemoteServiceOverrides`), so they must not run in parallel or one's `clearAll()` races another.
@Suite(.serialized) struct RemoteEndpointConfigTests {

    /// Mirrors the current https://drivechain.dev/config: an ARRAY of networks mapped by `id`
    /// (Bitcoin AND Signet both have `family: "bitcoin"` — so family can't identify a network),
    /// backends WITHOUT `priority` (array order = preference, esplora first), plus additive service
    /// fields we ignore (`blockbook`/`fast_withdrawal`) and per-network `assumeutxo`. Includes an
    /// unknown-id network for forward-compat.
    private static let validJSON = """
    {
      "schema_version": 1,
      "refresh_after_seconds": 600,
      "networks": [
        {
          "id": "bitcoin", "family": "bitcoin",
          "backends": [
            { "kind": "esplora",  "url": "https://esplora.mainnet.example", "tls": true, "label": "L2L Esplora" },
            { "kind": "electrum", "url": "ssl://electrum.mainnet.example:50002", "tls": true }
          ],
          "explorer_tx_template": "https://explorer.mainnet.example/tx/{txid}"
        },
        {
          "id": "signet", "family": "bitcoin",
          "backends": [
            { "kind": "esplora",  "url": "https://esplora.signet.example", "tls": true },
            { "kind": "electrum", "url": "ssl://node.signet.example:50002", "tls": true }
          ],
          "explorer_tx_template": "https://explorer.signet.example/tx/{txid}"
        },
        {
          "id": "drynet2", "family": "ecash",
          "backends": [
            { "kind": "esplora",  "url": "https://esplora.drynet2.drivechain.dev", "tls": true },
            { "kind": "electrum", "url": "ssl://drynet2.drivechain.dev:50012", "tls": true }
          ],
          "explorer_tx_template": "https://explorer.drynet2.drivechain.dev/tx/{txid}",
          "services": {
            "faucet":   { "url": "https://faucet.drynet2.example", "amount": 5, "cooldown_seconds": 1800 },
            "coinnews": { "url": "https://coinnews.drynet2.example" },
            "blockbook": { "url": "https://blockbook.drynet2.example" },
            "fast_withdrawal": []
          },
          "assumeutxo": { "url": "https://x/utxo.dat", "height": 957600, "sha256": "abc", "size_bytes": 123 }
        },
        {
          "id": "futurenet", "family": "future",
          "backends": [ { "kind": "esplora", "url": "https://esplora.future.example" } ]
        }
      ]
    }
    """

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Parsing

    @Test func parsesValidPayload() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))
        #expect(config != nil)
        #expect(config?.schemaVersion == 1)
        #expect(config?.refreshAfterSeconds == 600)
    }

    @Test func rejectsUnsupportedSchema() {
        let json = #"{ "schema_version": 2, "networks": [] }"#
        #expect(RemoteEndpointConfig.parse(data(json)) == nil)
    }

    @Test func rejectsMalformedJSON() {
        #expect(RemoteEndpointConfig.parse(data("not json at all")) == nil)
        #expect(RemoteEndpointConfig.parse(Data()) == nil)
    }

    /// A verbatim drynet2 entry from the current https://drivechain.dev/config (no `priority`; with
    /// `blockbook`/`fast_withdrawal`/`assumeutxo`/`currency`/`chain`/address+block templates). Lenient
    /// decoding must ignore the extras; the `drynet2` id must map to `.ecash`; esplora (first) wins.
    @Test func parsesRealEndpointShapeIgnoringExtraFields() {
        let json = """
        {
          "schema_version": 1,
          "networks": [
            {
              "id": "drynet2", "family": "ecash", "display_name": "Drynet 2",
              "description": "Fork of mainnet with PoW difficulty reset", "chain": "main",
              "currency": { "name": "eCash", "ticker": "ECX" },
              "backends": [
                { "kind": "esplora", "url": "https://esplora.drynet2.drivechain.dev", "tls": true, "label": "L2L Esplora" },
                { "kind": "electrum", "url": "ssl://drynet2.drivechain.dev:50012", "tls": true, "label": "L2L electrs" }
              ],
              "explorer_tx_template": "https://explorer.drynet2.drivechain.dev/tx/{txid}",
              "explorer_address_template": "https://explorer.drynet2.drivechain.dev/address/{address}",
              "explorer_block_template": "https://explorer.drynet2.drivechain.dev/block/{hash}",
              "services": { "faucet": { "url": null, "amount": null, "cooldown_seconds": null },
                            "coinnews": { "url": "https://coinnews.drynet2.drivechain.dev" },
                            "blockbook": { "url": "https://blockbook.drynet2.drivechain.dev" },
                            "fast_withdrawal": [] },
              "assumeutxo": { "url": "https://data.drivechain.dev/drynet2/utxo-957600.dat",
                              "height": 957600, "sha256": "473ae7", "size_bytes": 9498111432 }
            }
          ]
        }
        """
        let config = RemoteEndpointConfig.parse(data(json))
        #expect(config != nil)
        let backends = config?.resolvedPrimaryBackends() ?? []
        #expect(backends.count == 1)
        #expect(backends.first?.network == WalletNetwork.ecash)          // id "drynet2" → .ecash
        #expect(backends.first?.kind == "esplora")                       // first in array (no priority)
        #expect(backends.first?.url == "https://esplora.drynet2.drivechain.dev")
        // coinnews present; faucet is null → not resolved.
        #expect(config?.resolvedCoinNews().first?.url == "https://coinnews.drynet2.drivechain.dev")
        #expect(config?.resolvedFaucets().isEmpty == true)
    }

    /// The live config during the **drynet2 → drynet3 rollover**: BOTH carry `family: "ecash"`,
    /// drynet2 has EMPTY backends (decommissioned), drynet3 has the real ones. `.ecash` must resolve
    /// to **drynet3** — the empty drynet2 entry must not shadow it. (Regression for the 2026-07-23 bug:
    /// the old id-only mapping recognized `drynet2` but not `drynet3`, so `.ecash` fell back to the
    /// dead bundled endpoint.)
    @Test func drynetRolloverResolvesToTheLiveEcashEntry() {
        let json = """
        {
          "schema_version": 1,
          "networks": [
            { "id": "drynet2", "family": "ecash", "display_name": "Drynet 2", "backends": [] },
            { "id": "drynet3", "family": "ecash", "display_name": "Drynet 3",
              "backends": [
                { "kind": "esplora",  "url": "https://esplora.drynet3.drivechain.dev", "tls": true },
                { "kind": "electrum", "url": "ssl://drynet3.drivechain.dev:50012", "tls": true }
              ] }
          ]
        }
        """
        let backends = RemoteEndpointConfig.parse(data(json))?.resolvedPrimaryBackends() ?? []
        #expect(backends.count == 1)
        #expect(backends.first?.network == WalletNetwork.ecash)
        #expect(backends.first?.kind == "esplora")
        #expect(backends.first?.url == "https://esplora.drynet3.drivechain.dev")   // drynet3, not the empty drynet2
    }

    // MARK: - Resolution

    @Test func picksFirstBackendInArrayOrderWhenNoPriority() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!
        let resolved = config.resolvedPrimaryBackends()
        // Known networks: bitcoin, signet, ecash — "futurenet" (unknown id) is skipped.
        #expect(resolved.count == 3)

        // No priorities → the FIRST backend in array order (esplora) wins for each.
        let ecash = resolved.first { $0.network == WalletNetwork.ecash }
        #expect(ecash?.kind == "esplora")
        #expect(ecash?.url == "https://esplora.drynet2.drivechain.dev")
        #expect(resolved.first { $0.network == WalletNetwork.bitcoin }?.kind == "esplora")
        #expect(resolved.first { $0.network == WalletNetwork.signet }?.kind == "esplora")
    }

    /// The regression that motivated `id`-based mapping: Bitcoin and Signet BOTH carry
    /// `family: "bitcoin"`, yet must resolve to DISTINCT networks (not collide / drop signet).
    @Test func mapsSignetByIdNotFamilyDespiteSharedBitcoinFamily() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!
        let resolved = config.resolvedPrimaryBackends()
        #expect(resolved.first { $0.network == WalletNetwork.bitcoin }?.url == "https://esplora.mainnet.example")
        #expect(resolved.first { $0.network == WalletNetwork.signet }?.url == "https://esplora.signet.example")
    }

    @Test func explicitPriorityOverridesArrayOrder() {
        // When priorities ARE present, they win over array position: electrum (priority 1) beats
        // the first-listed esplora (priority 2).
        let json = """
        { "schema_version": 1, "networks": [ { "id": "drynet2", "backends": [
            { "kind": "esplora",  "url": "https://esplora.example",  "priority": 2 },
            { "kind": "electrum", "url": "ssl://electrum.example:50002", "priority": 1 }
        ] } ] }
        """
        let resolved = RemoteEndpointConfig.parse(data(json))!.resolvedPrimaryBackends()
        #expect(resolved.first?.kind == "electrum")
    }

    @Test func skipsUnknownNetworkIds() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!
        let networks = config.resolvedPrimaryBackends().map { $0.network }
        #expect(networks.contains(WalletNetwork.ecash))
        #expect(networks.contains(WalletNetwork.bitcoin))
        #expect(networks.contains(WalletNetwork.signet))
        // "futurenet" is not a known id → never resolved.
        #expect(networks.count == 3)
    }

    @Test func ignoresBackendsWithInvalidKind() {
        let json = """
        { "schema_version": 1, "networks": [
            { "id": "drynet2", "backends": [
              { "kind": "bogus",   "url": "https://bad.example", "priority": 1 },
              { "kind": "esplora", "url": "https://good.example", "priority": 2 }
            ] } ] }
        """
        let resolved = RemoteEndpointConfig.parse(data(json))!.resolvedPrimaryBackends()
        // The invalid kind is filtered out; the valid (higher-priority-number) one is used instead.
        #expect(resolved.count == 1)
        #expect(resolved.first?.url == "https://good.example")
    }

    @Test func networkWithNoValidBackendIsOmitted() {
        let json = #"{ "schema_version": 1, "networks": [ { "id": "drynet2", "backends": [] } ] }"#
        #expect(RemoteEndpointConfig.parse(data(json))!.resolvedPrimaryBackends().isEmpty)
    }

    // MARK: - Services resolution (faucet + coinnews)

    @Test func resolvesServiceOverlays() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!

        let coinNews = config.resolvedCoinNews()
        #expect(coinNews.count == 1)
        #expect(coinNews.first?.network == WalletNetwork.ecash)
        #expect(coinNews.first?.url == "https://coinnews.drynet2.example")

        let faucets = config.resolvedFaucets()
        #expect(faucets.count == 1)
        let faucet = faucets.first
        #expect(faucet?.network == WalletNetwork.ecash)
        #expect(faucet?.url == "https://faucet.drynet2.example")
        #expect(faucet?.amount == 5)
        #expect(faucet?.cooldownSeconds == 1800)
    }

    @Test func networksWithoutServicesResolveEmpty() {
        // bitcoin in the fixture has no `services` block → contributes nothing.
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!
        #expect(config.resolvedCoinNews().allSatisfy { $0.network != WalletNetwork.bitcoin })
        #expect(config.resolvedFaucets().allSatisfy { $0.network != WalletNetwork.bitcoin })
    }

    @Test func blankServiceURLsAreIgnored() {
        let json = """
        { "schema_version": 1, "networks": [ { "id": "drynet2", "services": {
            "faucet":   { "url": "  " },
            "coinnews": { "url": "" }
        } } ] }
        """
        let config = RemoteEndpointConfig.parse(data(json))!
        #expect(config.resolvedCoinNews().isEmpty)
        #expect(config.resolvedFaucets().isEmpty)
    }

    // MARK: - Service overlay store + registry precedence (overlay beats bundled)

    @Test func overlayStoreRoundTripsAndRegistriesConsultIt() {
        RemoteServiceOverrides.clearAll()
        defer { RemoteServiceOverrides.clearAll() }

        // Bundled state: eCash has no faucet and no CoinNews indexer → News tab off.
        #expect(FaucetRegistry.config(for: WalletNetwork.ecash) == nil)
        #expect(CoinNewsEndpointRegistry.publicEndpoint(for: WalletNetwork.ecash) == nil)
        #expect(CoinNewsAvailability.isAvailable(on: WalletNetwork.ecash) == false)

        // Apply a remote overlay (as AppState would from the fetched config).
        RemoteServiceOverrides.setFaucet(url: "https://faucet.drynet2.example",
                                         amount: 5, cooldownSeconds: 1800, for: WalletNetwork.ecash)
        #expect(RemoteServiceOverrides.setCoinNewsURL("https://coinnews.drynet2.example", for: WalletNetwork.ecash))

        // Registries now resolve the overlay, and CoinNews availability flips ON for eCash.
        let faucet = FaucetRegistry.config(for: WalletNetwork.ecash)
        #expect(faucet?.amount == 5)
        #expect(faucet?.endpoint.absoluteString == "https://faucet.drynet2.example")
        #expect(CoinNewsEndpointRegistry.publicEndpoint(for: WalletNetwork.ecash)?.baseURL.absoluteString == "https://coinnews.drynet2.example")
        #expect(CoinNewsAvailability.isAvailable(on: WalletNetwork.ecash) == true)

        // A deliberate product gate is not overridable by the overlay: Bitcoin mainnet stays off.
        RemoteServiceOverrides.setCoinNewsURL("https://evil.example", for: WalletNetwork.bitcoin)
        #expect(CoinNewsAvailability.isAvailable(on: WalletNetwork.bitcoin) == false)

        // setCoinNewsURL reports no-change on an identical re-apply (so feeds aren't needlessly rebuilt).
        #expect(RemoteServiceOverrides.setCoinNewsURL("https://coinnews.drynet2.example", for: WalletNetwork.ecash) == false)
    }

    // MARK: - Explorer overlay

    @Test func resolvesExplorerTemplates() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!
        let explorers = config.resolvedExplorers()
        // bitcoin, signet, and ecash all carry explorer templates in the fixture.
        #expect(explorers.count == 3)
        #expect(explorers.first { $0.network == WalletNetwork.ecash }?.txTemplate
                == "https://explorer.drynet2.drivechain.dev/tx/{txid}")
    }

    @Test func rejectsExplorerTemplateWithoutTxidPlaceholder() {
        let json = """
        { "schema_version": 1, "networks": [ { "id": "drynet2", "explorer_tx_template": "https://x.example/nope" } ] }
        """
        #expect(RemoteEndpointConfig.parse(data(json))!.resolvedExplorers().isEmpty)
    }

    @Test func explorerOverlayBeatsBundledElseFallsBack() {
        RemoteServiceOverrides.clearAll()
        defer { RemoteServiceOverrides.clearAll() }

        // No overlay → bundled NetworkRegistry template.
        #expect(RemoteServiceOverrides.explorerURL(for: "abc", on: WalletNetwork.ecash)
                == "https://explorer.drynet3.drivechain.dev/tx/abc")

        // Overlay wins and substitutes {txid}.
        RemoteServiceOverrides.setExplorerTemplate("https://scan.example/t/{txid}", for: WalletNetwork.ecash)
        #expect(RemoteServiceOverrides.explorerURL(for: "abc", on: WalletNetwork.ecash)
                == "https://scan.example/t/abc")

        // A template missing {txid} is ignored (bundled remains).
        RemoteServiceOverrides.clearAll()
        RemoteServiceOverrides.setExplorerTemplate("https://scan.example/no-placeholder", for: WalletNetwork.ecash)
        #expect(RemoteServiceOverrides.explorerURL(for: "abc", on: WalletNetwork.ecash)
                == "https://explorer.drynet3.drivechain.dev/tx/abc")
    }

    // MARK: - Refresh throttle

    @Test func throttleIsDueWhenNeverFetchedThenNotUntilIntervalElapses() {
        let suite = "test.remoteconfig.throttle"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Never fetched → due.
        #expect(RemoteConfigRefreshPolicy.isDue(now: t0, defaults: d) == true)

        // Record a fetch with a 600s interval → not due 5 min later, due 11 min later.
        RemoteConfigRefreshPolicy.recordFetch(interval: 600, now: t0, defaults: d)
        #expect(RemoteConfigRefreshPolicy.isDue(now: t0.addingTimeInterval(300), defaults: d) == false)
        #expect(RemoteConfigRefreshPolicy.isDue(now: t0.addingTimeInterval(660), defaults: d) == true)
    }

    @Test func throttleClampsTinyIntervalToFloor() {
        let suite = "test.remoteconfig.throttle.floor"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }

        let t0 = Date(timeIntervalSince1970: 2_000_000)
        // A server value of 0 must not cause fetch-every-resume — clamp to the 60s floor.
        RemoteConfigRefreshPolicy.recordFetch(interval: 0, now: t0, defaults: d)
        #expect(RemoteConfigRefreshPolicy.isDue(now: t0.addingTimeInterval(30), defaults: d) == false)
        #expect(RemoteConfigRefreshPolicy.isDue(now: t0.addingTimeInterval(90), defaults: d) == true)
    }

    // MARK: - Service (fail-safe fetch)

    @Test func serviceLoadsAndResolves() async {
        let service = RemoteEndpointConfigService(url: URL(string: "https://config.test/v1.json")!) { _ in
            self.data(Self.validJSON)
        }
        let config = await service.load()
        #expect(config != nil)
        let resolved = config?.resolvedPrimaryBackends() ?? []
        #expect(resolved.count == 3)
        #expect(resolved.contains { $0.network == WalletNetwork.ecash && $0.kind == "esplora" })
    }

    @Test func serviceFailsSafeOnFetchError() async {
        struct Boom: Error {}
        let service = RemoteEndpointConfigService(url: URL(string: "https://config.test/v1.json")!) { _ in
            throw Boom()
        }
        // No network → nil config (caller keeps last-known-good / bundled).
        let config = await service.load()
        #expect(config == nil)
    }

    @Test func serviceFailsSafeOnMalformedResponse() async {
        let service = RemoteEndpointConfigService(url: URL(string: "https://config.test/v1.json")!) { _ in
            self.data("garbage")
        }
        let config = await service.load()
        #expect(config == nil)
    }

    // MARK: - Fork height must track the SAME entry as the backend

    /// The live config lists drynet2/3/4, all `family: "ecash"`. Backend selection is first-wins among
    /// entries that HAVE a usable backend, so decommissioned drynet2 is skipped and drynet3 wins. The
    /// fork height must come from that same entry — a naive "apply them all" loop lets the last entry
    /// win (drynet4's 961632) while the app talks to drynet3 (957600), and every coin confirmed
    /// between those heights gets wrongly flagged as needing a split.
    @Test func forkHeightComesFromTheSameEntryAsTheBackend() throws {
        let json = """
        {"schema_version":1,"networks":[
          {"id":"drynet2","family":"ecash","fork_height":957600,"backends":[]},
          {"id":"drynet3","family":"ecash","fork_height":957600,
           "backends":[{"kind":"esplora","url":"https://esplora.drynet3.example"}]},
          {"id":"drynet4","family":"ecash","fork_height":961632,
           "backends":[{"kind":"esplora","url":"https://esplora.drynet4.example"}]}
        ]}
        """
        let config = try #require(RemoteEndpointConfig.parse(Data(json.utf8)))

        let backend = try #require(config.resolvedPrimaryBackends().first { $0.network == WalletNetwork.ecash })
        #expect(backend.url == "https://esplora.drynet3.example")

        let heights = config.resolvedForkHeights().filter { $0.network == WalletNetwork.ecash }
        #expect(heights.count == 1)                 // exactly one winner, not three
        #expect(heights.first?.height == 957_600)   // drynet3's — matching the backend we adopted
    }

    /// When drynet3 is retired (no usable backend), drynet4 becomes the live entry and its height
    /// must follow automatically — that's the rollover this whole mechanism exists for.
    @Test func forkHeightFollowsTheRolloverWhenTheOldChainRetires() throws {
        let json = """
        {"schema_version":1,"networks":[
          {"id":"drynet3","family":"ecash","fork_height":957600,"backends":[]},
          {"id":"drynet4","family":"ecash","fork_height":961632,
           "backends":[{"kind":"esplora","url":"https://esplora.drynet4.example"}]}
        ]}
        """
        let config = try #require(RemoteEndpointConfig.parse(Data(json.utf8)))
        #expect(config.resolvedPrimaryBackends().first { $0.network == WalletNetwork.ecash }?.url
                == "https://esplora.drynet4.example")
        #expect(config.resolvedForkHeights().first { $0.network == WalletNetwork.ecash }?.height == 961_632)
    }

    /// The display name must follow the same entry as the backend and fork height. Labelling the UI
    /// "Drynet 3" while syncing drynet4 is precisely the confusion this mechanism removes.
    @Test func displayNameComesFromTheLiveEntry() throws {
        let json = """
        {"schema_version":1,"networks":[
          {"id":"drynet2","family":"ecash","display_name":"Drynet 2","fork_height":957600,"backends":[]},
          {"id":"drynet3","family":"ecash","display_name":"Drynet 3","fork_height":957600,
           "backends":[{"kind":"esplora","url":"https://esplora.drynet3.example"}]},
          {"id":"drynet4","family":"ecash","display_name":"Drynet 4","fork_height":961632,
           "backends":[{"kind":"esplora","url":"https://esplora.drynet4.example"}]}
        ]}
        """
        let config = try #require(RemoteEndpointConfig.parse(Data(json.utf8)))
        let names = config.resolvedDisplayNames().filter { $0.network == WalletNetwork.ecash }
        #expect(names.count == 1)
        #expect(names.first?.name == "Drynet 3")   // the live entry, not the newest listed
    }

    /// Once drynet3 has no backend, the name rolls over with everything else.
    @Test func displayNameFollowsTheRollover() throws {
        let json = """
        {"schema_version":1,"networks":[
          {"id":"drynet3","family":"ecash","display_name":"Drynet 3","fork_height":957600,"backends":[]},
          {"id":"drynet4","family":"ecash","display_name":"Drynet 4","fork_height":961632,
           "backends":[{"kind":"esplora","url":"https://esplora.drynet4.example"}]}
        ]}
        """
        let config = try #require(RemoteEndpointConfig.parse(Data(json.utf8)))
        #expect(config.resolvedDisplayNames().first { $0.network == WalletNetwork.ecash }?.name == "Drynet 4")
        #expect(config.resolvedForkHeights().first { $0.network == WalletNetwork.ecash }?.height == 961_632)
    }
}
