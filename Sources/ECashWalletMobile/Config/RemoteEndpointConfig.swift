// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The decoded network-config payload served from `https://drivechain.dev/config`
/// (`RemoteEndpointConfigService`).
///
/// This carries **rotatable, non-consensus data only** — backend endpoints, explorer tx-URL
/// templates, and faucet/CoinNews service URLs. Consensus/derivation params (coin-type, HRP, unit
/// label, network magic) are NEVER read from here; they stay in the app's compiled `NetworkRegistry`
/// (Golden Rule §1/§4). The payload's richer metadata (`currency`, `chain`, `display_name`,
/// address/block explorer templates) is intentionally **ignored** — decoding is lenient so extra
/// fields never break an older app, and any decode failure yields `nil`, which the caller treats as
/// "keep the last-known-good / bundled endpoints" (graceful fallback).
///
/// **Network identity:** `networks` is an ARRAY; each entry is mapped to one of our `WalletNetwork`
/// cases by its **`id`** (`bitcoin`/`signet`/`drynet2`). We map by `id`, NOT `family`, because
/// `family` is a chain *category*, not a network — both Bitcoin mainnet and Signet report
/// `family: "bitcoin"` (changed server-side 2026-07-19), so it can't identify a network. `bitcoin`/
/// `signet` ids match our rawValues directly; the eCash test net's id is `drynet2` today (aliased to
/// `.ecash`) and will map straight through if it's ever renamed `ecash`. Unknown ids are skipped
/// (forward-compat).
struct RemoteEndpointConfig: Equatable, Sendable {
    /// The schema this app understands. A payload with a different `schemaVersion` is ignored.
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let refreshAfterSeconds: Int?
    let networks: [RemoteNetwork]

    struct RemoteNetwork: Equatable, Sendable {
        let id: String?
        let family: String?
        let backends: [RemoteBackend]
        let explorerTxTemplate: String?
        let services: RemoteServices?

        /// The `WalletNetwork` this entry maps to (by `id`), or nil if unknown to this app.
        /// `bitcoin`/`signet` ids match our rawValues; the eCash test net's id `drynet2` is aliased
        /// to `.ecash` (a future `ecash` id would map straight through via rawValue).
        var walletNetwork: WalletNetwork? {
            guard let id else { return nil }
            if let known = WalletNetwork(rawValue: id) { return known }
            switch id {
            case "drynet2": return .ecash
            default: return nil
            }
        }
    }

    struct RemoteBackend: Equatable, Sendable {
        let kind: String            // "electrum" | "esplora"
        let url: String
        let priority: Int?          // lower = preferred; missing sorts last
    }

    struct RemoteServices: Equatable, Sendable {
        let faucet: RemoteFaucet?
        let coinnews: RemoteService?
    }

    struct RemoteService: Equatable, Sendable {
        let url: String?            // nil / absent = service off for this network
    }

    struct RemoteFaucet: Equatable, Sendable {
        let url: String?
        let amount: Double?
        let cooldownSeconds: Int?
    }

    /// A backend resolved to a known `WalletNetwork`, ready to hand to `WalletManager`.
    struct ResolvedBackend: Equatable, Sendable {
        let network: WalletNetwork
        let kind: String
        let url: String
    }

    /// A CoinNews indexer URL resolved to a known `WalletNetwork`.
    struct ResolvedCoinNews: Equatable, Sendable {
        let network: WalletNetwork
        let url: String
    }

    /// A faucet resolved to a known `WalletNetwork` (url required; amount/cooldown optional).
    struct ResolvedFaucet: Equatable, Sendable {
        let network: WalletNetwork
        let url: String
        let amount: Double?
        let cooldownSeconds: Int?
    }

    /// An explorer tx-URL template resolved to a known `WalletNetwork`.
    struct ResolvedExplorer: Equatable, Sendable {
        let network: WalletNetwork
        let txTemplate: String
    }

    // MARK: - Parsing

    /// Decode a payload. Returns `nil` on malformed JSON or a schema this app doesn't support —
    /// never throws, so a bad response degrades to the bundled defaults rather than an error.
    static func parse(_ data: Data) -> RemoteEndpointConfig? {
        guard let config = try? JSONDecoder().decode(RemoteEndpointConfig.self, from: data) else {
            return nil
        }
        guard config.schemaVersion == supportedSchemaVersion else { return nil }
        return config
    }

    // MARK: - Resolution
    //
    // Each resolver maps entries to a `WalletNetwork` by `family` (see type doc), skips unknown
    // networks, and returns a deterministic order (by rawValue). If the same family ever appears
    // twice, the FIRST entry in array order wins (a `seen` guard) — today there is one per family.

    /// The primary backend per **known** `WalletNetwork`.
    /// - The preferred backend is the lowest `priority`; when `priority` is absent (the server
    ///   dropped it 2026-07-19), the FIRST valid backend in **array order** wins — ties always
    ///   break by array position, so selection is deterministic with or without priorities.
    /// - Only `electrum`/`esplora` kinds are accepted; anything else is ignored so a typo in the
    ///   config can never produce an unusable backend.
    func resolvedPrimaryBackends() -> [ResolvedBackend] {
        var result: [ResolvedBackend] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, seen.insert(walletNetwork.rawValue).inserted else { continue }
            let best = network.backends.enumerated()
                .filter { Self.isValidKind($0.element.kind) && !$0.element.url.trimmingCharacters(in: .whitespaces).isEmpty }
                .min { lhs, rhs in
                    let lp = lhs.element.priority ?? Int.max
                    let rp = rhs.element.priority ?? Int.max
                    return lp != rp ? lp < rp : lhs.offset < rhs.offset   // tie → array order
                }?.element
            guard let best else { continue }
            result.append(ResolvedBackend(network: walletNetwork,
                                          kind: best.kind,
                                          url: best.url.trimmingCharacters(in: .whitespaces)))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// CoinNews indexer URL per **known** network that supplies a non-empty `services.coinnews.url`.
    func resolvedCoinNews() -> [ResolvedCoinNews] {
        var result: [ResolvedCoinNews] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, seen.insert(walletNetwork.rawValue).inserted else { continue }
            guard let url = Self.cleaned(network.services?.coinnews?.url) else { continue }
            result.append(ResolvedCoinNews(network: walletNetwork, url: url))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// Faucet config per **known** network that supplies a non-empty `services.faucet.url`.
    func resolvedFaucets() -> [ResolvedFaucet] {
        var result: [ResolvedFaucet] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, seen.insert(walletNetwork.rawValue).inserted else { continue }
            guard let url = Self.cleaned(network.services?.faucet?.url) else { continue }
            result.append(ResolvedFaucet(network: walletNetwork,
                                         url: url,
                                         amount: network.services?.faucet?.amount,
                                         cooldownSeconds: network.services?.faucet?.cooldownSeconds))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// Explorer tx-URL template per **known** network that supplies a non-empty, `{txid}`-bearing
    /// `explorer_tx_template`. A template without the `{txid}` placeholder is rejected.
    func resolvedExplorers() -> [ResolvedExplorer] {
        var result: [ResolvedExplorer] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, seen.insert(walletNetwork.rawValue).inserted else { continue }
            guard let template = Self.cleaned(network.explorerTxTemplate), template.contains("{txid}") else { continue }
            result.append(ResolvedExplorer(network: walletNetwork, txTemplate: template))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    private static func isValidKind(_ kind: String) -> Bool {
        kind == "electrum" || kind == "esplora"
    }

    /// Trim + reject empty/nil. A blank URL means "no service", not a valid endpoint.
    private static func cleaned(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Codable (snake_case ↔ camelCase via explicit keys; unknown fields ignored)

extension RemoteEndpointConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case refreshAfterSeconds = "refresh_after_seconds"
        case networks
    }
}

extension RemoteEndpointConfig.RemoteNetwork: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, family, backends, services
        case explorerTxTemplate = "explorer_tx_template"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? c.decodeIfPresent(String.self, forKey: .id)
        self.family = try? c.decodeIfPresent(String.self, forKey: .family)
        // `backends` may be absent for a network that only lists services — default to empty.
        self.backends = (try? c.decode([RemoteEndpointConfig.RemoteBackend].self, forKey: .backends)) ?? []
        self.explorerTxTemplate = try? c.decodeIfPresent(String.self, forKey: .explorerTxTemplate)
        self.services = try? c.decodeIfPresent(RemoteEndpointConfig.RemoteServices.self, forKey: .services)
    }
}

extension RemoteEndpointConfig.RemoteBackend: Decodable {
    enum CodingKeys: String, CodingKey {
        case kind, url, priority
    }
}

extension RemoteEndpointConfig.RemoteServices: Decodable {
    enum CodingKeys: String, CodingKey {
        case faucet, coinnews
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.faucet = try? c.decodeIfPresent(RemoteEndpointConfig.RemoteFaucet.self, forKey: .faucet)
        self.coinnews = try? c.decodeIfPresent(RemoteEndpointConfig.RemoteService.self, forKey: .coinnews)
    }
}

extension RemoteEndpointConfig.RemoteService: Decodable {
    enum CodingKeys: String, CodingKey { case url }
}

extension RemoteEndpointConfig.RemoteFaucet: Decodable {
    enum CodingKeys: String, CodingKey {
        case url, amount
        case cooldownSeconds = "cooldown_seconds"
    }
}
