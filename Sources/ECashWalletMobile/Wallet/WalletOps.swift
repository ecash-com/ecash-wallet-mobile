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
    func rescan(walletId: String) async throws -> Amount
    func balanceAsync(walletId: String) async throws -> Amount
    func pendingBalanceAsync(walletId: String) async throws -> Amount
    func transactionsAsync(walletId: String) async throws -> [WalletTx]
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
    /// Deposit into a BIP300 sidechain (M5). `address` is the BARE sidechain address; the treasury
    /// fields come from the enforcer and are re-verified by the engine (`docs/sidechain-deposits.md`).
    func depositToSidechain(walletId: String, slot: Int32, address: String, amount: Amount, feeRate: FeeRate,
                            treasuryTxid: String?, treasuryVout: Int32, treasuryValueSats: Int64) async throws -> WalletTx
    /// Read-only split status (total spendable vs pre-fork amount that needs splitting).
    func splitSummary(walletId: String) throws -> SplitSummary
    func splitSummary(walletId: String, knownShared: [String], knownSafe: [String]) throws -> SplitSummary
    func splitCandidates(walletId: String) throws -> [Utxo]
    /// Purge engine-held state for a wallet that is being removed (Golden Rule §5). The BDK side purges
    /// through `WalletManager.removeWallet`, so its implementation is the default no-op; Thunder keeps
    /// app-side stores (revealed index, first-seen times, account public key) that must go too.
    func forget(walletId: String)
}

extension WalletOps {
    func forget(walletId: String) {}
}
