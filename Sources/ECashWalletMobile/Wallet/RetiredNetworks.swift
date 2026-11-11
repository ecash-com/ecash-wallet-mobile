// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import WalletService

/// The "Hide retired networks" setting (Settings → Network; ON by default — Jake, 2026-11-09).
/// Alphanet, betanet and Thunder-betanet accounts drop out of the wallet list and the network
/// switcher, and a wallet whose accounts are ALL on retired networks drops out of the list.
///
/// Presentation only. Nothing here deletes, re-keys, or stops syncing anything: a hidden wallet
/// is one flip of the switch away, and `AppState.wallets` (what `hasWallets` and onboarding read)
/// is never filtered. Two guard rails:
///
/// - **Never an empty list.** If every wallet is retired-only, nothing is hidden — the welcome
///   screen is for people with no wallets, not for people whose wallets are old.
/// - **The account a wallet is open on is always shown**, so what Home displays is always findable
///   in the list and the switcher.
enum RetiredNetworks {
    static let defaultsKey = "hideRetiredNetworks"

    /// Every account on a retired network — the whole wallet is "old".
    static func isRetiredOnly(_ wallet: ManagedWallet) -> Bool {
        wallet.accounts.allSatisfy { $0.network.isRetired }
    }

    /// The wallets to list. With hiding on, retired-only wallets are dropped — unless that would
    /// drop them all, in which case the list is left alone (`isShowingRetiredFallback`).
    static func visibleWallets(_ wallets: [ManagedWallet], hiding: Bool) -> [ManagedWallet] {
        guard hiding else { return wallets }
        let kept = wallets.filter { !isRetiredOnly($0) }
        return kept.isEmpty ? wallets : kept
    }

    static func hiddenCount(_ wallets: [ManagedWallet], hiding: Bool) -> Int {
        wallets.count - visibleWallets(wallets, hiding: hiding).count
    }

    /// Hiding is on, but every wallet is retired-only, so none is hidden.
    static func isShowingRetiredFallback(_ wallets: [ManagedWallet], hiding: Bool) -> Bool {
        hiding && !wallets.isEmpty && wallets.allSatisfy(isRetiredOnly)
    }

    /// Networks to offer in the switcher, or account lines to show in a row: retired ones go, except
    /// the one the wallet is currently open on.
    static func visibleNetworks(_ networks: [WalletNetwork], current: WalletNetwork?, hiding: Bool) -> [WalletNetwork] {
        guard hiding else { return networks }
        return networks.filter { !$0.isRetired || $0 == current }
    }

    /// Which wallet should be selected: the current one if it is visible, else the first visible.
    /// `nil` only when there are no wallets at all.
    static func selection(current: String?, visible: [ManagedWallet]) -> String? {
        if let current, visible.contains(where: { $0.id == current }) { return current }
        return visible.first?.id
    }
}
