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

    /// A faithful payload (mirrors https://drivechain.dev/config), with an extra backend + an
    /// unknown-family network to exercise priority selection and forward-compat.
    private static let validJSON = """
    {
      "schema_version": 1,
      "refresh_after_seconds": 600,
      "networks": [
        {
          "id": "bitcoin", "family": "bitcoin",
          "backends": [
            { "kind": "electrum", "url": "ssl://electrum.blockstream.info:50002", "priority": 1 }
          ],
          "explorer_tx_template": "https://mempool.space/tx/{txid}"
        },
        {
          "id": "drynet2", "family": "ecash",
          "backends": [
            { "kind": "electrum", "url": "ssl://electrum.drynet2.example:50002", "priority": 2 },
            { "kind": "esplora",  "url": "https://esplora.drynet2.drivechain.dev", "priority": 1 }
          ],
          "explorer_tx_template": "https://explorer.drynet2.drivechain.dev/tx/{txid}",
          "services": {
            "faucet":   { "url": "https://faucet.drynet2.example", "amount": 5, "cooldown_seconds": 1800 },
            "coinnews": { "url": "https://coinnews.drynet2.example" }
          }
        },
        {
          "id": "futurenet", "family": "futurefamily",
          "backends": [ { "kind": "esplora", "url": "https://esplora.future.example", "priority": 1 } ]
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

    /// The real https://drivechain.dev/config entry carries extra fields we don't consume
    /// (`family`, `display_name`, `description`, `chain`, `currency`, address/block templates).
    /// Lenient decoding must ignore them, and the `drynet2`/family-`ecash` entry must map to `.ecash`.
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
                { "kind": "esplora", "url": "https://esplora.drynet2.drivechain.dev", "priority": 1, "tls": true, "label": "L2L Esplora" },
                { "kind": "electrum", "url": "ssl://drynet2.drivechain.dev:50012", "priority": 2, "tls": true, "label": "L2L electrs" }
              ],
              "explorer_tx_template": "https://explorer.drynet2.drivechain.dev/tx/{txid}",
              "explorer_address_template": "https://explorer.drynet2.drivechain.dev/address/{address}",
              "explorer_block_template": "https://explorer.drynet2.drivechain.dev/block/{hash}",
              "services": { "faucet": { "url": null, "amount": null, "cooldown_seconds": null },
                            "coinnews": { "url": "https://coinnews.drynet2.drivechain.dev" } }
            }
          ]
        }
        """
        let config = RemoteEndpointConfig.parse(data(json))
        #expect(config != nil)
        let backends = config?.resolvedPrimaryBackends() ?? []
        #expect(backends.count == 1)
        #expect(backends.first?.network == WalletNetwork.ecash)          // family "ecash" → .ecash
        #expect(backends.first?.kind == "esplora")                       // priority 1 wins
        #expect(backends.first?.url == "https://esplora.drynet2.drivechain.dev")
        // coinnews present; faucet is null → not resolved.
        #expect(config?.resolvedCoinNews().first?.url == "https://coinnews.drynet2.drivechain.dev")
        #expect(config?.resolvedFaucets().isEmpty == true)
    }

    // MARK: - Resolution

    @Test func picksLowestPriorityBackendPerNetwork() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!
        let resolved = config.resolvedPrimaryBackends()
        // Known networks only (bitcoin, ecash) — "futurenet" is skipped. Deterministic order.
        #expect(resolved.count == 2)

        let ecash = resolved.first { $0.network == WalletNetwork.ecash }
        // priority 1 esplora wins over priority 2 electrum — and the URL has NO /api suffix.
        #expect(ecash?.kind == "esplora")
        #expect(ecash?.url == "https://esplora.drynet2.drivechain.dev")
        #expect(ecash?.url.hasSuffix("/api") == false)

        let bitcoin = resolved.first { $0.network == WalletNetwork.bitcoin }
        #expect(bitcoin?.kind == "electrum")
    }

    @Test func skipsUnknownNetworkKeys() {
        let config = RemoteEndpointConfig.parse(data(Self.validJSON))!
        let networks = config.resolvedPrimaryBackends().map { $0.network }
        #expect(networks.contains(WalletNetwork.ecash))
        #expect(networks.contains(WalletNetwork.bitcoin))
        // "futurenet" is not a known WalletNetwork → never resolved.
        #expect(networks.count == 2)
    }

    @Test func ignoresBackendsWithInvalidKind() {
        let json = """
        { "schema_version": 1, "networks": [
            { "family": "ecash", "backends": [
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
        let json = #"{ "schema_version": 1, "networks": [ { "family": "ecash", "backends": [] } ] }"#
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
        { "schema_version": 1, "networks": [ { "family": "ecash", "services": {
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
        // bitcoin + ecash carry explorer templates in the fixture; signet does not.
        #expect(explorers.count == 2)
        #expect(explorers.first { $0.network == WalletNetwork.ecash }?.txTemplate
                == "https://explorer.drynet2.drivechain.dev/tx/{txid}")
    }

    @Test func rejectsExplorerTemplateWithoutTxidPlaceholder() {
        let json = """
        { "schema_version": 1, "networks": [ { "family": "ecash", "explorer_tx_template": "https://x.example/nope" } ] }
        """
        #expect(RemoteEndpointConfig.parse(data(json))!.resolvedExplorers().isEmpty)
    }

    @Test func explorerOverlayBeatsBundledElseFallsBack() {
        RemoteServiceOverrides.clearAll()
        defer { RemoteServiceOverrides.clearAll() }

        // No overlay → bundled NetworkRegistry template.
        #expect(RemoteServiceOverrides.explorerURL(for: "abc", on: WalletNetwork.ecash)
                == "https://explorer.drynet2.drivechain.dev/tx/abc")

        // Overlay wins and substitutes {txid}.
        RemoteServiceOverrides.setExplorerTemplate("https://scan.example/t/{txid}", for: WalletNetwork.ecash)
        #expect(RemoteServiceOverrides.explorerURL(for: "abc", on: WalletNetwork.ecash)
                == "https://scan.example/t/abc")

        // A template missing {txid} is ignored (bundled remains).
        RemoteServiceOverrides.clearAll()
        RemoteServiceOverrides.setExplorerTemplate("https://scan.example/no-placeholder", for: WalletNetwork.ecash)
        #expect(RemoteServiceOverrides.explorerURL(for: "abc", on: WalletNetwork.ecash)
                == "https://explorer.drynet2.drivechain.dev/tx/abc")
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
        #expect(resolved.count == 2)
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
}
