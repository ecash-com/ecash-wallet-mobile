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
        switch network {
        case .signet:
            // L2L drivechain signet indexer (galaxoidlabs), live 2026-06.
            guard let url = URL(string: "https://coinnews.signet.dc.galaxoidlabs.com") else { return nil }
            return CoinNewsEndpoint(baseURL: url)
        case .bitcoin, .testnet4, .regtest:
            // No public indexer yet.
            return nil
        }
    }
}
