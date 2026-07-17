// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The public `coinnews.v1` indexer endpoint per network (CoinNews is on-chain per network, so its
/// indexer is too). Unauthenticated, HTTPS — consumed via `CoinNewsV1Client`. Networks without a
/// hosted indexer return `nil` (→ empty feed; no hardcoded data).
enum CoinNewsEndpointRegistry {
    static func publicEndpoint(for network: WalletNetwork) -> CoinNewsEndpoint? {
        // Remote overlay wins over the bundled default (below the dev-env override applied in
        // AppState.makeCoinNewsFetcher). Lets a drynet2/eCash indexer be turned on from the config
        // with no app update — the News tab lights up on the next launch.
        if let remote = RemoteServiceOverrides.coinNewsURL(for: network) {
            return CoinNewsEndpoint(baseURL: remote)
        }
        switch network {
        case .signet:
            // L2L drivechain signet CoinNews indexer.
            guard let url = URL(string: "https://coinnews.signet.drivechain.info") else { return nil }
            return CoinNewsEndpoint(baseURL: url)
        case .bitcoin:
            // No public indexer (and none wanted on mainnet — see CoinNewsAvailability).
            return nil
        case .ecash:
            // eCash (drynet2): no bundled indexer yet — supplied via the remote overlay above when
            // one is live. Until then this is nil and the News tab stays hidden.
            return nil
        }
    }
}
