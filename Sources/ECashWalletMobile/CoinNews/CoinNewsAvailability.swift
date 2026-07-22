// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import WalletService

/// Whether CoinNews is offered on a given network — a **code-level, non-user-facing** capability
/// (like `NetworkChipStyle`), not a Settings toggle. CoinNews is an L2L feature, so it's off on
/// **Bitcoin mainnet** and on for the testnet-class networks. When unavailable, the News tab is
/// hidden for that wallet's network entirely.
///
/// Adding eCash networks later is one case each here. The `switch` is exhaustive on purpose: a new
/// `WalletNetwork` case won't compile until its CoinNews availability is decided.
enum CoinNewsAvailability {
    static func isAvailable(on network: WalletNetwork) -> Bool {
        switch network {
        case .bitcoin: return false          // deliberate: no CoinNews on Bitcoin mainnet, ever
        case .signet: return true
        case .ecash:
            // eCash (drynet2): available exactly when an indexer endpoint resolves — i.e. once the
            // remote config supplies a coinnews URL (RemoteServiceOverlay), the News tab appears on
            // its own with no app update. Nil today → hidden.
            return CoinNewsEndpointRegistry.publicEndpoint(for: .ecash) != nil
        case .thunder: return false          // Thunder has no CoinNews
        }
    }
}
