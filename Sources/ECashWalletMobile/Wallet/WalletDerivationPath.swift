// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The printable derivation path of one of a wallet's keys, for Receive and tx detail.
///
/// BDK wallets read it from their descriptor's key origin (`ManagedWallet.derivationPath`). Thunder has
/// no descriptor — its keys come from the sidechain key scheme (ristretto255 on
/// `m/43'/1899'/0'/9'/0'/index`, one address chain, so `isChange` doesn't change the path).
enum WalletDerivationPath {
    static func path(for wallet: ManagedWallet, isChange: Bool, index: Int32) -> String? {
        switch wallet.network {
        case .thunder:
            return ThunderKey.scheme.derivationPath(index: index)
        case .bitcoin, .signet, .ecash, .ecashBeta:
            return wallet.derivationPath(isChange: isChange, index: index)
        }
    }
}
