// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Per-network faucet config (endpoint + amount) — a **code-level, non-user-facing** capability,
/// mirroring `CoinNewsEndpointRegistry`: testnet-feature endpoints live app-side here, NOT in the
/// bridged `NetworkRegistry`. A faucet dispenses **valueless** test coins, so it exists only on test
/// networks. `config(for:)` returns `nil` where there's no faucet, which is the single on/off + the
/// signet-only gate: to disable the faucet, return `nil` for that network (or comment its case).
///
/// The `switch` is exhaustive on purpose: a new `WalletNetwork` won't compile until its faucet
/// availability is decided.
enum FaucetRegistry {
    /// What a network's faucet offers. `amount` is whole test coins (a `Double` — the faucet RPC
    /// takes a double); `cooldown` is the client-side wait before another request is allowed (our own
    /// UX guard on top of the server's rate limit). Change them here.
    struct Config {
        let endpoint: URL
        let amount: Double
        let cooldown: TimeInterval
    }

    static func config(for network: WalletNetwork) -> Config? {
        switch network {
        case .signet:
            // L2L drivechain signet faucet (ConnectRPC unary, HTTP+JSON — same transport as CoinNews).
            // Endpoint base; the client appends `faucet.v1.FaucetService/DispenseCoins`.
            guard let url = URL(string: "https://node.signet.drivechain.info/api") else { return nil }
            return Config(endpoint: url, amount: 3, cooldown: 3600)   // ← amount + cooldown (1h) here
        case .bitcoin:
            return nil   // no faucet on real money
        }
    }

    /// Whether to offer the faucet button for `network` (i.e. a config exists).
    static func isAvailable(on network: WalletNetwork) -> Bool {
        config(for: network) != nil
    }
}
