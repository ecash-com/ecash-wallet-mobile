// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Adapts the bridged `WalletManager` (the BDK path — Bitcoin/eCash) to `WalletOps` by forwarding each
/// call unchanged. This is the `primary` route in `WalletFacade`: every non-Thunder wallet goes
/// through here exactly as it does today.
final class WalletManagerOps: WalletOps {
    private let manager: WalletManager

    init(_ manager: WalletManager) { self.manager = manager }

    func balance(walletId: String) throws -> Amount { try manager.balance(walletId: walletId) }
    func pendingBalance(walletId: String) throws -> Amount { try manager.pendingBalance(walletId: walletId) }
    func sync(walletId: String) async throws -> Amount { try await manager.sync(walletId: walletId) }
    func nextReceiveAddress(walletId: String) throws -> AddressInfo { try manager.nextReceiveAddress(walletId: walletId) }
    func nextUnusedAddress(walletId: String) throws -> AddressInfo { try manager.nextUnusedAddress(walletId: walletId) }
    func transactions(walletId: String) throws -> [WalletTx] { try manager.transactions(walletId: walletId) }
    func send(walletId: String, to address: String, amount: Amount, feeRate: FeeRate) async throws -> WalletTx {
        try await manager.send(walletId: walletId, to: address, amount: amount, feeRate: feeRate)
    }
}
