// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Routes each per-wallet operation to the engine that backs that wallet: Thunder wallets to the
/// Fuse-native `ThunderService`, everything else (Bitcoin/eCash) to the bridged BDK `WalletManager`
/// (via `WalletManagerOps`). This is the seam that makes "Thunder is just another network" work even
/// though Thunder's engine lives on the opposite side of the Fuse/Lite boundary from BDK (BDK is
/// sealed inside the transpiled WalletService package behind a `@nobridge` seam; Thunder must be
/// Fuse-native because swift-crypto/BLAKE3 can't transpile — see docs/thunder-sidechain-support.md).
/// The app depends on `WalletOps`, never on which engine runs a given wallet.
///
/// `isThunder` decides the route per walletId. It's injected rather than hardcoded to
/// `network == .thunder` so this layer lands and is tested BEFORE the `WalletNetwork.thunder` case
/// exists; wire it to the real network check (`manager.wallets.first { $0.id == id }?.network ==
/// .thunder`) once that case is added.
final class WalletFacade: WalletOps {
    private let primary: WalletOps
    private let thunder: WalletOps
    private let isThunder: (String) -> Bool

    init(primary: WalletOps, thunder: WalletOps, isThunder: @escaping (String) -> Bool) {
        self.primary = primary
        self.thunder = thunder
        self.isThunder = isThunder
    }

    private func route(_ walletId: String) -> WalletOps { isThunder(walletId) ? thunder : primary }

    func balance(walletId: String) throws -> Amount { try route(walletId).balance(walletId: walletId) }
    func pendingBalance(walletId: String) throws -> Amount { try route(walletId).pendingBalance(walletId: walletId) }
    func sync(walletId: String) async throws -> Amount { try await route(walletId).sync(walletId: walletId) }
    func nextReceiveAddress(walletId: String) throws -> AddressInfo { try route(walletId).nextReceiveAddress(walletId: walletId) }
    func nextUnusedAddress(walletId: String) throws -> AddressInfo { try route(walletId).nextUnusedAddress(walletId: walletId) }
    func transactions(walletId: String) throws -> [WalletTx] { try route(walletId).transactions(walletId: walletId) }
    func send(walletId: String, to address: String, amount: Amount, feeRate: FeeRate) async throws -> WalletTx {
        try await route(walletId).send(walletId: walletId, to: address, amount: amount, feeRate: feeRate)
    }
}
