// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// A wallet's last-known balance for list rows (the wallet manager, the send destination picker) —
/// wallets the user is *not* currently looking at.
///
/// **Why this isn't just an `Amount`.** A wallet engine only knows what its local chain data says, so
/// a wallet that has never completed a sync on this device reports `0` — indistinguishable, at the
/// type level, from a wallet that synced and is genuinely empty. Printing "0" for the first case is a
/// lie the UI would be telling about someone's money, and in a list of wallets to move funds *into*
/// it's exactly the kind of thing that makes a person think they picked the wrong wallet. So the
/// unknown case is modelled, not flattened.
enum WalletBalanceSummary: Equatable, Hashable {
    /// Synced at least once; this is the balance as of then (may be stale, never invented).
    case known(Amount)
    /// Never synced on this device — we genuinely don't know, and say so.
    case unknown

    var amount: Amount? {
        switch self {
        case let .known(amount): return amount
        case .unknown: return nil
        }
    }

    /// Display string for a list row — "0.00123456 ECX" — or nil when unknown, in which case the
    /// caller shows a localized "Not synced" instead of a number it can't stand behind.
    func displayText(unitLabel: String) -> String? {
        guard let amount else { return nil }
        return "\(amount.formattedCoin()) \(unitLabel)"
    }
}

/// Remembers which wallets have completed a sync on this device.
///
/// Nothing in `ManagedWallet` or BDK's store answers "has this ever synced?" — an empty synced wallet
/// and a never-synced wallet look identical — so we record it ourselves. Public data (a timestamp),
/// so `UserDefaults`, not the Keychain.
struct WalletSyncStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ walletId: String) -> String { "wallet.syncedAt.\(walletId)" }

    func hasSynced(walletId: String) -> Bool { defaults.object(forKey: key(walletId)) != nil }

    func markSynced(walletId: String, at epochSeconds: Int64) {
        defaults.set(epochSeconds, forKey: key(walletId))
    }

    /// Drop the marker when a wallet is removed, so a later wallet reusing the id can't inherit it.
    func forget(walletId: String) { defaults.removeObject(forKey: key(walletId)) }
}
