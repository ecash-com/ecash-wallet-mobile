// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// Two eCash chains published at once (2026-09-17): `alphanet` and `betanet`.
///
/// Before this, entries were mapped to `.ecash` by **`family: "ecash"`** — which worked only while
/// exactly one eCash chain existed at a time (`drynet2` → `drynet3` → …). With both live, BOTH
/// matched `.ecash`, and first-usable-wins meant betanet was silently swallowed: its backends AND
/// its different fork height. The fork height is the part that makes this a money bug rather than a
/// missing menu entry — `SplitSummary.classify` uses it to decide which coins are pre-fork and need
/// splitting, so alphanet's 963_648 applied to a betanet wallet misclassifies everything in the
/// 4_032-block gap between them.
@Suite struct EcashBetanetConfigTests {

    /// The live payload's shape, trimmed to what matters here.
    private static let bothChains = """
    {
      "schema_version": 1,
      "networks": [
        {
          "id": "alphanet", "family": "ecash", "display_name": "Alphanet",
          "fork_height": 963648,
          "backends": [ { "kind": "esplora", "url": "https://esplora.alpha.ecash.ninja" } ],
          "explorer_tx_template": "https://explorer.alpha.ecash.ninja/tx/{txid}"
        },
        {
          "id": "betanet", "family": "ecash", "display_name": "Betanet",
          "fork_height": 967680,
          "backends": [ { "kind": "esplora", "url": "https://esplora.beta.ecash.ninja" } ],
          "explorer_tx_template": "https://explorer.beta.ecash.ninja/tx/{txid}"
        }
      ]
    }
    """

    private static func parse(_ json: String) -> RemoteEndpointConfig {
        let cfg = RemoteEndpointConfig.parse(Data(json.utf8))
        #expect(cfg != nil)
        return cfg!
    }

    // MARK: - The regression this exists for

    @Test func alphanetAndBetanetResolveToDifferentNetworks() {
        let cfg = Self.parse(Self.bothChains)
        let mapped = cfg.networks.compactMap(\.walletNetwork)
        #expect(mapped == [.ecash, .ecashBeta])
    }

    /// The money-safety assertion: each chain keeps ITS OWN fork height. Sharing one would
    /// misclassify every coin in the gap between them.
    @Test func eachChainKeepsItsOwnForkHeight() {
        let heights = Self.parse(Self.bothChains).resolvedForkHeights()
        #expect(heights.first(where: { $0.network == .ecash })?.height == 963_648)
        #expect(heights.first(where: { $0.network == .ecashBeta })?.height == 967_680)
    }

    @Test func eachChainKeepsItsOwnBackend() {
        let cfg = Self.parse(Self.bothChains)
        let alpha = cfg.networks.first { $0.walletNetwork == .ecash }
        let beta  = cfg.networks.first { $0.walletNetwork == .ecashBeta }
        #expect(alpha?.backends.first?.url == "https://esplora.alpha.ecash.ninja")
        #expect(beta?.backends.first?.url == "https://esplora.beta.ecash.ninja")
    }

    @Test func eachChainKeepsItsOwnDisplayName() {
        let names = Self.parse(Self.bothChains).resolvedDisplayNames()
        #expect(names.first(where: { $0.network == .ecash })?.name == "Alphanet")
        #expect(names.first(where: { $0.network == .ecashBeta })?.name == "Betanet")
    }

    // MARK: - Don't break what already worked

    /// Older payloads carried ONE eCash entry identified only by family. Existing installs must keep
    /// resolving it, so the family fallback stays — it is just no longer reached first.
    @Test func aLoneFamilyEcashEntryStillResolvesToAlphanet() {
        let cfg = Self.parse("""
        {"schema_version":1,"networks":[
          {"id":"drynet3","family":"ecash","fork_height":957600,
           "backends":[{"kind":"esplora","url":"https://esplora.drynet3.example"}]}]}
        """)
        #expect(cfg.networks.compactMap(\.walletNetwork) == [.ecash])
    }

    @Test func bitcoinAndSignetStillMapByIdNotFamily() {
        let cfg = Self.parse("""
        {"schema_version":1,"networks":[
          {"id":"bitcoin","family":"bitcoin","backends":[{"kind":"esplora","url":"https://a.example"}]},
          {"id":"signet","family":"bitcoin","backends":[{"kind":"esplora","url":"https://b.example"}]}]}
        """)
        #expect(cfg.networks.compactMap(\.walletNetwork) == [.bitcoin, .signet])
    }

    // MARK: - Identity

    /// The persisted rawValue is what `check_network` enforces on load. Renaming `.ecash` would
    /// orphan every existing eCash wallet, which is why the case still carries the awkward name and
    /// the user-facing label comes from the config's `display_name` instead.
    @Test func persistedRawValuesAreStable() {
        #expect(WalletNetwork.ecash.rawValue == "ecash")
        #expect(WalletNetwork.ecashBeta.rawValue == "ecashBeta")
        #expect(WalletNetwork(rawValue: "ecash") == .ecash)
    }

    @Test func betanetIsOfferedInThePicker() {
        #expect(WalletNetwork.selectable.contains(.ecashBeta))
        #expect(WalletNetwork.selectable.contains(.ecash))
    }

    /// Both are Bitcoin-identical, so one seed derives the SAME addresses on each — the chip is the
    /// only thing telling them apart, so it must not be the same colour.
    @Test func betanetDerivesLikeAlphanetButIsChippedDifferently() {
        #expect(NetworkRegistry.params(for: .ecashBeta).coinType == NetworkRegistry.params(for: .ecash).coinType)
        #expect(NetworkRegistry.params(for: .ecashBeta).addressHRP == "bc")
        #expect(NetworkRegistry.params(for: .ecashBeta).unitLabel == "ECX")
        #expect(!WalletNetwork.ecashBeta.isMainnet)
    }

    // MARK: - Chain currency and capability

    /// The claim button and both create/import defaults read `currentEcash`. Alphanet still runs but
    /// is no longer where the work is (2026-09-21), so new wallets and investor claims land on
    /// betanet. Existing alphanet wallets are untouched — network is fixed at creation.
    @Test func newWalletsAndClaimsPointAtBetanet() {
        #expect(WalletNetwork.currentEcash == .ecashBeta)
    }

    /// **The regression this file's second half exists for.** Split-coins was gated by six scattered
    /// `== .ecash` comparisons, so adding betanet wired its fork height (967_680) correctly and then
    /// threw it away: `splitSummary` was forced nil, the Home nudge never appeared, and the Settings
    /// row stayed hidden — on the chain whose whole point is separating forked coins. Equality checks
    /// are invisible to the exhaustiveness checker that caught every other per-network site.
    @Test func bothEcashChainsSupportCoinSplitting() {
        #expect(WalletNetwork.ecash.supportsCoinSplit)
        #expect(WalletNetwork.ecashBeta.supportsCoinSplit)
    }

    /// Splitting is meaningless where there is no shared pre-fork history.
    @Test func nonForkNetworksDoNotSupportCoinSplitting() {
        #expect(!WalletNetwork.bitcoin.supportsCoinSplit)
        #expect(!WalletNetwork.signet.supportsCoinSplit)
        #expect(!WalletNetwork.thunder.supportsCoinSplit)
    }

}
