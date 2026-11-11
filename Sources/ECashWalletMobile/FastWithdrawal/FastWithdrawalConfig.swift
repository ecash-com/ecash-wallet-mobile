// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Everything you'd want to change about fast withdrawal without touching the flow:
/// the on/off switch and where each sidechain's service lives. See `docs/fast-withdrawal.md`.
enum FastWithdrawalConfig {

    /// **The switch.** `false` hides the "Fast withdrawal" option everywhere (it shows as "Coming
    /// soon" in the Withdraw sheet) and stops any background polling. Withdrawals already in flight
    /// are kept on disk and reappear when it's turned back on.
    ///
    /// OFF for now (2026-10-21): the flow is built and tested against fakes but hasn't been exercised
    /// against the live betanet service yet. Flip to `true` to ship it.
    static let isEnabled = false

    /// The service for withdrawals FROM `sidechain`, or nil when there isn't one (the option is then
    /// hidden). Exhaustive on purpose: a new network won't compile until someone decides.
    static func endpoint(forSidechain sidechain: WalletNetwork) -> Endpoint? {
        switch sidechain {
        case .thunder:
            // Thunder → betanet L1. Run by the L2L team (2026-10-13).
            return Endpoint(baseURL: URL(string: "https://fastwithdraw.betanet.ecash.ninja"),
                            sidechainID: "thunder",
                            operatorName: "L2L",
                            pinnedQuoteKeyBase64: nil)
        // No fast-withdrawal service for Thunder mainnet yet (betanet's is the only one, 2026-11-10).
        case .bitcoin, .signet, .ecash, .ecashBeta, .ecashMainnet, .thunderMainnet:
            return nil   // not sidechains
        }
    }

    struct Endpoint: Equatable {
        /// Optional only because `URL(string:)` is; a nil here means "no service".
        let baseURL: URL?
        /// The `sidechain` value the service expects in requests and signs into quotes.
        let sidechainID: String
        /// Who the user is trusting. Shown on the review screen.
        let operatorName: String
        /// The quote signing key (base64, 32 bytes) the app expects, or nil to accept the one the
        /// service reports in `GetServiceInfo`. Pinning catches a swapped server or key, at the cost
        /// of breaking the feature if the operator rotates it — so it stays nil on betanet.
        let pinnedQuoteKeyBase64: String?
    }

    /// The endpoint, if the feature is on and the sidechain has a service.
    static func activeEndpoint(forSidechain sidechain: WalletNetwork) -> Endpoint? {
        guard isEnabled, let endpoint = endpoint(forSidechain: sidechain), endpoint.baseURL != nil else { return nil }
        return endpoint
    }
}
