// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Which of the user's own wallets can receive a deposit into sidechain `slot` on `mainchain`.
/// Drives the deposit flow's "Deposit to one of my wallets" list, like Send's same-network filter.
///
/// **This is a safety filter, not a convenience.** A Thunder wallet in this app is BETANET
/// Thunder (`.thunder` reads the betanet index). Offering it for a deposit made from another
/// mainchain would credit a Thunder address on a chain that wallet never looks at. So a wallet
/// type is listed only for the exact (mainchain, slot) pair it belongs to.
///
/// Exhaustive on purpose: the real eCash fork won't compile until someone decides whether this
/// app's Thunder wallets belong to it (`docs/real-ecash-fork-transition.md`).
enum SidechainWalletNetwork {
    /// The mainchain a sidechain wallet type belongs to: where its deposits come from, and so which
    /// explorer shows a deposit's (mainchain) transaction.
    static func mainchain(ofSidechainWallet network: WalletNetwork) -> WalletNetwork? {
        switch network {
        case .thunder: return .ecashBeta
        case .bitcoin, .signet, .ecash, .ecashBeta: return nil
        }
    }

    static func walletNetwork(forSlot slot: Int, onMainchain mainchain: WalletNetwork) -> WalletNetwork? {
        switch mainchain {
        case .ecashBeta:
            return slot == ThunderAddress.sidechainNumber ? .thunder : nil
        case .ecash, .signet, .bitcoin, .thunder:
            // Alphanet and signet have no Thunder wallet type in this app; Bitcoin has no BIP300;
            // Thunder is itself a sidechain.
            return nil
        }
    }
}
