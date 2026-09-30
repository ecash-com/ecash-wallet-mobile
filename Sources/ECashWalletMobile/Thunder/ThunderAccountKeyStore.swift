// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Each Thunder wallet's account PUBLIC key ("xpub"), per `walletId` — what lets sync, Receive and change
/// addresses derive without loading the mnemonic. Computed once from the seed (at the first moment the
/// wallet needs an address), then reused; only signing touches the seed after that. The same
/// watch-only + sign-on-demand model as the BDK side, whose public descriptors live at rest too.
///
/// Public data, so not the Keychain — but privacy-sensitive like any xpub (it links every address the
/// wallet will ever use), so it is purged with the wallet (Golden Rule §5).
protocol ThunderAccountKeyStoring {
    func accountKey(walletId: String) -> RistrettoBip32.PublicKey?
    func setAccountKey(_ key: RistrettoBip32.PublicKey, walletId: String)
    func forget(walletId: String)
}

struct UserDefaultsThunderAccountKeyStore: ThunderAccountKeyStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Versioned by key scheme: a future Thunder key change must never reuse a stored xpub derived the
    /// old way (the 0.18 port is exactly that situation for the pre-0.18 ed25519 scheme).
    private func key(_ walletId: String) -> String { "thunder.accountKey.v018.\(walletId)" }

    // A JSON string, not a plist dictionary — `UserDefaults.dictionary(forKey:)` is unavailable in
    // Skip's Foundation on Android (see UserDefaultsThunderFirstSeenStore).
    func accountKey(walletId: String) -> RistrettoBip32.PublicKey? {
        guard let json = defaults.string(forKey: key(walletId)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RistrettoBip32.PublicKey.self, from: data)
    }

    func setAccountKey(_ accountKey: RistrettoBip32.PublicKey, walletId: String) {
        guard let data = try? JSONEncoder().encode(accountKey),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: key(walletId))
    }

    func forget(walletId: String) { defaults.removeObject(forKey: key(walletId)) }
}

/// In-memory variant for tests.
final class InMemoryThunderAccountKeyStore: ThunderAccountKeyStoring, @unchecked Sendable {
    private var keys: [String: RistrettoBip32.PublicKey] = [:]

    init() {}

    func accountKey(walletId: String) -> RistrettoBip32.PublicKey? { keys[walletId] }
    func setAccountKey(_ key: RistrettoBip32.PublicKey, walletId: String) { keys[walletId] = key }
    func forget(walletId: String) { keys[walletId] = nil }
}
