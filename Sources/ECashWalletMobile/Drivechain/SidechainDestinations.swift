// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Which of the user's wallets a sidechain deposit or withdrawal can be addressed to — the "one of
/// my wallets" picker's rows — with the wallet they are in listed first and marked as such.
///
/// Pure, so the rules are tested without an `AppState`. Both lists are built from what a wallet
/// CAN hold, not from the network it happens to be switched to: under the seed-container model the
/// depositing wallet is on eCash by definition, and so is nearly every other wallet, so a filter on
/// the selected network listed nobody (the 1.5.0 bug: "Deposit to one of my wallets" never showed).
enum SidechainDestinations {
    /// Deposit candidates: every seed wallet, since each derives its Thunder account from its own
    /// phrase on first use (a WIF wallet has one key and no Thunder). The wallet being deposited
    /// FROM is first — depositing to the same seed is the common case.
    static func deposit(wallets: [ManagedWallet], currentId: String, receiving: WalletNetwork?,
                        balance: (String) -> WalletBalanceSummary) -> [SendViewModel.Destination] {
        guard let receiving, receiving.isThunder else { return [] }
        return ordered(wallets.filter { $0.keyType == .mnemonic }, currentId: currentId, balance: balance)
    }

    /// Withdrawal candidates: every wallet with an account on the mainchain the coins return to,
    /// whichever account it is switched to. The withdrawing wallet's own mainchain account first.
    static func withdraw(wallets: [ManagedWallet], currentId: String, mainchain: WalletNetwork,
                         balance: (String) -> WalletBalanceSummary) -> [SendViewModel.Destination] {
        ordered(wallets.filter { wallet in wallet.accounts.contains { $0.network == mainchain } },
                currentId: currentId, balance: balance)
    }

    private static func ordered(_ wallets: [ManagedWallet], currentId: String,
                                balance: (String) -> WalletBalanceSummary) -> [SendViewModel.Destination] {
        let current = wallets.filter { $0.id == currentId }
        let others = wallets.filter { $0.id != currentId }
        return (current + others).map { wallet in
            SendViewModel.Destination(id: wallet.id, label: wallet.label, balance: balance(wallet.id),
                                      isCurrent: wallet.id == currentId)
        }
    }
}
