// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The per-wallet operations the app performs, abstracted over the engine that backs a given wallet.
/// The Bitcoin/eCash path (BDK, via the bridged `WalletManager`) is one implementation and the Thunder
/// path (`ThunderService`, Fuse-native) is another; `WalletFacade` routes per network so the app/view
/// models depend only on this surface, not on which engine runs behind a wallet.
///
/// The method shapes mirror the bridged `WalletManager` ops exactly, so this is a drop-in for the
/// app's existing call sites. CoinNews publish ops are intentionally absent — they're Bitcoin/eCash-
/// only and stay on `WalletManager` directly (Thunder has no CoinNews).
protocol WalletOps {
    func balance(walletId: String) throws -> Amount
    func pendingBalance(walletId: String) throws -> Amount
    func sync(walletId: String) async throws -> Amount
    func nextReceiveAddress(walletId: String) throws -> AddressInfo
    func nextUnusedAddress(walletId: String) throws -> AddressInfo
    func transactions(walletId: String) throws -> [WalletTx]
    func send(walletId: String, to address: String, amount: Amount, feeRate: FeeRate) async throws -> WalletTx
}
