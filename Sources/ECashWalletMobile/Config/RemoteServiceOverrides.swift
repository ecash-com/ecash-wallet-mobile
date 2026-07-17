// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Last-known-good **remote overlay** for the per-network *services* (CoinNews indexer + faucet),
/// persisted in UserDefaults. This is the services analog of `WalletManager`'s remote backend layer:
/// the fetched `wallet-endpoints/v1.json` writes here, and `CoinNewsEndpointRegistry` / `FaucetRegistry`
/// read here FIRST, falling back to their bundled (compiled) defaults when nothing is stored — so a
/// service can be turned on / repointed by editing the config and redeploying, no app update needed.
///
/// Precedence (highest first) stays: explicit override (e.g. the CoinNews dev-env endpoint) → this
/// remote overlay → bundled default. Only URLs (+ faucet amount/cooldown) live here — never
/// consensus/derivation params (Golden Rule §1/§4). Persisted so a cold/offline launch still has the
/// last-known-good service URLs before the next fetch completes.
enum RemoteServiceOverrides {
    private static var defaults: UserDefaults { .standard }

    private static func coinNewsKey(_ n: WalletNetwork) -> String { "remote.svc.coinnews.\(n.rawValue).url" }
    private static func faucetURLKey(_ n: WalletNetwork) -> String { "remote.svc.faucet.\(n.rawValue).url" }
    private static func faucetAmountKey(_ n: WalletNetwork) -> String { "remote.svc.faucet.\(n.rawValue).amount" }
    private static func faucetCooldownKey(_ n: WalletNetwork) -> String { "remote.svc.faucet.\(n.rawValue).cooldown" }
    private static func explorerKey(_ n: WalletNetwork) -> String { "remote.svc.explorer.\(n.rawValue).template" }

    private static func trimmedOrNil(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Read (consulted by the registries)

    /// Remotely-configured CoinNews indexer URL for a network, or nil if none stored.
    static func coinNewsURL(for network: WalletNetwork) -> URL? {
        guard let s = trimmedOrNil(defaults.string(forKey: coinNewsKey(network))) else { return nil }
        return URL(string: s)
    }

    /// Remotely-configured faucet for a network, or nil if none stored. `amount`/`cooldown` fall
    /// back to sensible defaults when the config omitted them.
    static func faucet(for network: WalletNetwork) -> (url: URL, amount: Double, cooldown: TimeInterval)? {
        guard let s = trimmedOrNil(defaults.string(forKey: faucetURLKey(network))), let url = URL(string: s) else {
            return nil
        }
        let amount = defaults.object(forKey: faucetAmountKey(network)) as? Double ?? 1
        let cooldown = defaults.object(forKey: faucetCooldownKey(network)) as? Double ?? 3600
        return (url, amount, cooldown)
    }

    /// Resolve the explorer tx URL for a network: the remote overlay template if one is stored, else
    /// the bundled `NetworkRegistry` template. `{txid}` is substituted in either case.
    static func explorerURL(for txid: String, on network: WalletNetwork) -> String {
        if let template = trimmedOrNil(defaults.string(forKey: explorerKey(network))) {
            return template.replacingOccurrences(of: "{txid}", with: txid)
        }
        return NetworkRegistry.explorerURL(for: txid, on: network)
    }

    // MARK: - Write (applied from the fetched config)

    /// Set/replace the remote CoinNews URL for a network. Returns true if the stored value changed
    /// (so the caller can rebuild the feed / re-evaluate tab visibility only when needed).
    @discardableResult
    static func setCoinNewsURL(_ url: String, for network: WalletNetwork) -> Bool {
        guard let clean = trimmedOrNil(url) else { return false }
        guard defaults.string(forKey: coinNewsKey(network)) != clean else { return false }
        defaults.set(clean, forKey: coinNewsKey(network))
        return true
    }

    static func setFaucet(url: String, amount: Double?, cooldownSeconds: Int?, for network: WalletNetwork) {
        guard let clean = trimmedOrNil(url) else { return }
        defaults.set(clean, forKey: faucetURLKey(network))
        if let amount { defaults.set(amount, forKey: faucetAmountKey(network)) }
        if let cooldownSeconds { defaults.set(Double(cooldownSeconds), forKey: faucetCooldownKey(network)) }
    }

    /// Set/replace the remote explorer tx-URL template for a network (must contain `{txid}`).
    static func setExplorerTemplate(_ template: String, for network: WalletNetwork) {
        guard let clean = trimmedOrNil(template), clean.contains("{txid}") else { return }
        defaults.set(clean, forKey: explorerKey(network))
    }

    /// Clear all stored service overlays (full reset / tests).
    static func clearAll() {
        for n in WalletNetwork.allCases {
            defaults.removeObject(forKey: coinNewsKey(n))
            defaults.removeObject(forKey: faucetURLKey(n))
            defaults.removeObject(forKey: faucetAmountKey(n))
            defaults.removeObject(forKey: faucetCooldownKey(n))
            defaults.removeObject(forKey: explorerKey(n))
        }
    }
}
