// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The ONE network the dashboard reports on: betanet today, mainnet as soon as it's live
/// (`docs/dashboard-plan.md` D3). Deliberately not the selected wallet's network and not user-picked —
/// the dashboard is about the eCash chain, whichever wallet happens to be open.
///
/// The switch at the fork is a remote-config value (`dashboard` in `drivechain.dev/config`), so every
/// installed app follows on its next config fetch with no release. This is display data only — it
/// never routes a wallet anywhere (that stays `RemoteEndpointConfig.RemoteNetwork.walletNetwork`'s
/// allow-list).
struct DashboardNetwork: Equatable, Codable, Sendable {
    /// Stable id ("betanet"). Keys the caches, so a config flip never shows one network's cached
    /// numbers under another's name.
    let id: String
    /// Shown in section headers ("Betanet").
    let displayName: String
    /// The chain explorer (mempool-style API under `/api`), e.g. `https://explorer.beta.ecash.ninja`.
    let explorerURL: String
    /// The `releases.ecash.com/L1-ecash-bitcoin/<channel>/` directory for this network's node builds.
    let releasesChannel: String

    /// The wallet network this is, if the app has one: betanet → `.ecashBeta`. Nil for a network the
    /// app has no wallets for yet (mainnet, until its case exists). Same id allow-list as the config's
    /// backend routing, so the two can't disagree about which network an id means.
    var walletNetwork: WalletNetwork? { RemoteEndpointConfig.RemoteNetwork.walletNetwork(forId: id) }

    static let betanet = DashboardNetwork(id: "betanet", displayName: "Betanet",
                                          explorerURL: "https://explorer.beta.ecash.ninja",
                                          releasesChannel: "betanet")

    /// The configured network, or betanet when the config hasn't said (or said something unusable).
    static var current: DashboardNetwork { RemoteServiceOverrides.dashboardNetwork() ?? .betanet }
}
