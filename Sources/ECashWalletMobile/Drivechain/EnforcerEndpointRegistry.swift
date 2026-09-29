// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Where each network's BIP300 enforcer lives. A code-level, non-user-facing capability, like
/// `FaucetRegistry` and `CoinNewsEndpointRegistry`. It's a **service URL, not a consensus
/// parameter**, so the remote config may repoint it (`services.enforcer.url`). The deposit opcode
/// and slot rules never come from here (`docs/sidechain-deposits.md` §2a).
///
/// `endpoint(for:)` returning `nil` is the single gate for every sidechain surface on that network.
/// No enforcer means no sidechain list, and without a list we must not offer a deposit.
///
/// The `switch` is exhaustive on purpose: a new `WalletNetwork` won't compile until someone decides
/// whether it has sidechains.
enum EnforcerEndpointRegistry {
    static func endpoint(for network: WalletNetwork) -> URL? {
        if let remote = RemoteServiceOverrides.enforcerURL(for: network) { return remote }
        switch network {
        case .ecashBeta:
            // Hosted by L2L, the same one BitWindow's light mode uses. Verified 2026-09-29.
            return URL(string: "https://seed.beta.ecash.eu.com/enforcer")
        case .ecash:
            // Alphanet. `seed.alpha.ecash.eu.com/enforcer` answers, but with BETANET's chain (same
            // tip hash, betanet's activation height 967,680). Using it would show betanet's
            // sidechains on an alphanet wallet and build deposits on a treasury that doesn't exist
            // there. Off until L2L points it at alphanet; the remote overlay above can turn it on.
            return nil
        case .signet:
            // L2L Signet runs BIP300, but no public enforcer has been found for it yet.
            return nil
        case .bitcoin:
            return nil   // no BIP300 on Bitcoin
        case .thunder:
            return nil   // a sidechain itself, not a mainchain
        }
    }

    static func isAvailable(on network: WalletNetwork) -> Bool {
        endpoint(for: network) != nil
    }
}
