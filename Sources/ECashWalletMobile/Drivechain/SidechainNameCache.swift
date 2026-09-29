// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Last-known sidechain names per network (slot → title), persisted in UserDefaults. The engine
/// labels a deposit with its slot only; this lets Activity say "Deposit to Thunder" on a cold,
/// offline launch instead of "slot 9".
///
/// Display only, and harmless if stale: a slot's name is whatever the enforcer last said. Nothing
/// that moves money reads it.
enum SidechainNameCache {
    private static func key(_ network: WalletNetwork) -> String { "sidechain.names.\(network.rawValue)" }

    static func load(for network: WalletNetwork) -> [Int: String] {
        guard let json = UserDefaults.standard.string(forKey: key(network)),
              let stored = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else {
            return [:]
        }
        var names: [Int: String] = [:]
        for (slot, title) in stored {
            if let n = Int(slot) { names[n] = title }
        }
        return names
    }

    /// Stored as a JSON string: `UserDefaults.dictionary(forKey:)` doesn't exist on Fuse-Android.
    static func save(_ names: [Int: String], for network: WalletNetwork) {
        var stored: [String: String] = [:]
        for (slot, title) in names { stored[String(slot)] = title }
        guard let data = try? JSONEncoder().encode(stored), let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: key(network))
    }

    static func clearAll() {
        for n in WalletNetwork.allCases { UserDefaults.standard.removeObject(forKey: key(n)) }
    }
}
