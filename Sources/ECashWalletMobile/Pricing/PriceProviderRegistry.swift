// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import WalletService

/// Maps each network to the price provider bundled for its coin — a **code-level** decision, not a
/// user setting. Testnet-class networks have **no** provider (their coins have no fiat value), so the
/// UI shows no fiat for them. When eCash mainnet lands it gets its own provider entry here; nothing
/// else changes. Mirrors `NetworkRegistry`'s role for chain params.
enum PriceProviderRegistry {
    /// The bundled provider for `network`, or `nil` if the network has no meaningful fiat price.
    static func provider(for network: WalletNetwork) -> PriceProvider? {
        switch network {
        case .bitcoin:
            return BitfinexPriceProvider()
        case .signet:
            return nil
        case .ecash:
            // eCash (drynet2) dry-run coins have no fiat value — no provider (no fiat line).
            // When real eCash has a market, add its provider here.
            return nil
        case .thunder:
            return nil   // Thunder (test) coins have no fiat price
        }
    }

    /// Whether `network` has a fiat price at all (drives whether the UI shows a fiat line).
    static func supportsPricing(_ network: WalletNetwork) -> Bool {
        provider(for: network) != nil
    }
}
