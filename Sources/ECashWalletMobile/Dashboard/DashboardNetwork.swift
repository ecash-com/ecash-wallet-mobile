// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The ONE network the dashboard reports on: **eCash mainnet** (since 1.4.6 build 44, 2026-10-29 — betanet
/// before; `docs/dashboard-plan.md` D3). Deliberately not the selected wallet's network and not
/// user-picked — the dashboard is about the eCash chain, whichever wallet happens to be open.
///
/// A remote-config `dashboard` block (`dev.ecash.com/config`) can still override it; the live config
/// has never carried one, which is why the bundled default is mainnet rather than waiting on a
/// fetch (the Android 1.4.6 lesson). This is display data only — it never routes a wallet anywhere
/// (that stays `RemoteEndpointConfig.RemoteNetwork.walletNetwork`'s allow-list).
struct DashboardNetwork: Equatable, Codable, Sendable {
    /// Stable id ("ecash" — the config's id for the real fork). Keys the caches, so a config flip
    /// never shows one network's cached numbers under another's name.
    let id: String
    /// Shown in section headers ("eCash").
    let displayName: String
    /// The chain explorer (mempool-style API under `/api`), e.g. `https://explorer.ecash.ninja`.
    let explorerURL: String
    /// The `releases.ecash.com/L1-ecash-bitcoin/<channel>/` directory for this network's node builds.
    let releasesChannel: String

    /// The wallet network this is, if the app has one: `ecash` → `.ecashMainnet`. Nil for an id the
    /// app has no wallets for. Same id allow-list as the config's backend routing, so the two can't
    /// disagree about which network an id means.
    var walletNetwork: WalletNetwork? { RemoteEndpointConfig.RemoteNetwork.walletNetwork(forId: id) }

    /// The real fork. Explorer verified 2026-10-29 (`/api/blocks/tip/height`, `/api/v1/blocks`,
    /// `/api/mempool` all answer); `releases.ecash.com/L1-ecash-bitcoin/mainnet/latest/release.json`
    /// exists with the same fields as betanet's.
    static let mainnet = DashboardNetwork(id: "ecash", displayName: "eCash",
                                          explorerURL: "https://explorer.ecash.ninja",
                                          releasesChannel: "mainnet")

    /// The configured network, or mainnet when the config hasn't said (or said something unusable).
    static var current: DashboardNetwork { RemoteServiceOverrides.dashboardNetwork() ?? .mainnet }
}
