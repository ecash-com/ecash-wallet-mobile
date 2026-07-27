// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Remembers the highest address index a wallet has ever revealed, per `walletId`.
///
/// **Why this has to be persisted.** Thunder's SLIP-0010 ed25519 derivation is all-hardened, so there
/// is no watch-only xpub and no BDK-style "revealed SPKs" store to lean on — the app is the only thing
/// that knows how far down the address chain a wallet has gone. If the counter resets on relaunch we
/// get both classic failures: the Receive screen hands out an address the user already published
/// (address reuse, a privacy leak), and `sync` only asks the node about a shallow prefix of addresses,
/// so **funds paid to a high index look missing** until something scans deeper. This wallet has already
/// been bitten by the second one on the BDK side (docs: sync scan model / receive discipline) — no
/// funds are ever lost, since every index re-derives from the one seed, but "my money is gone" is not
/// a thing a wallet should ever say.
protocol ThunderAddressIndexStoring {
    func revealedIndex(walletId: String) -> UInt32
    func setRevealedIndex(_ index: UInt32, walletId: String)
}

/// The shipping store: one small integer per wallet in `UserDefaults`. Public data (an index, not a
/// key), so it does not belong in the Keychain.
struct UserDefaultsThunderAddressIndexStore: ThunderAddressIndexStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ walletId: String) -> String { "thunder.revealedIndex.\(walletId)" }

    func revealedIndex(walletId: String) -> UInt32 {
        UInt32(max(0, defaults.integer(forKey: key(walletId))))
    }

    func setRevealedIndex(_ index: UInt32, walletId: String) {
        // Monotonic: never walk the counter backwards, or we'd start re-issuing old addresses.
        guard index > revealedIndex(walletId: walletId) else { return }
        defaults.set(Int(index), forKey: key(walletId))
    }
}

/// In-memory variant for tests — same semantics, no `UserDefaults` side effects.
final class InMemoryThunderAddressIndexStore: ThunderAddressIndexStoring, @unchecked Sendable {
    private var indices: [String: UInt32] = [:]

    init() {}

    func revealedIndex(walletId: String) -> UInt32 { indices[walletId] ?? 0 }

    func setRevealedIndex(_ index: UInt32, walletId: String) {
        guard index > (indices[walletId] ?? 0) else { return }
        indices[walletId] = index
    }
}
