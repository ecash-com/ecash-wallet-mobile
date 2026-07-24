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
///
/// `@MainActor`: routing (which reads `WalletManager` state) and the observable updates that follow
/// must happen on the main actor — the async ops still hop off-main *inside* `WalletManager.sync/send`
/// (those are non-isolated) for the actual network I/O, so the main thread isn't blocked.
@MainActor
protocol WalletOps {
    func balance(walletId: String) throws -> Amount
    func pendingBalance(walletId: String) throws -> Amount
    func sync(walletId: String) async throws -> Amount
    /// A receive address: `unused: true` = the default (lowest unused, doesn't advance); `false` =
    /// reveal a fresh one ("New address"). **Async** so an engine whose derivation is heavy (Thunder:
    /// Keychain read + PBKDF2 + SLIP-0010 + BLAKE3) can run it OFF the main actor and not jank the
    /// Receive sheet's present animation. BDK stays fast (a cached watch-only lookup).
    func receiveAddress(walletId: String, unused: Bool) async throws -> AddressInfo
    func transactions(walletId: String) throws -> [WalletTx]
    func send(walletId: String, to address: String, amount: Amount, feeRate: FeeRate) async throws -> WalletTx
    /// Sweep the entire spendable balance to `address` (true drain — the correct "Max" + split-coins).
    func sweep(walletId: String, to address: String, feeRate: FeeRate) async throws -> WalletTx
    /// Split coins: drain the whole balance to a fresh address of ITSELF (wallet-owned destination).
    func splitToSelf(walletId: String, feeRate: FeeRate) async throws -> WalletTx
    /// Read-only split status (total spendable vs pre-fork amount that needs splitting).
    func splitSummary(walletId: String) throws -> SplitSummary
}
