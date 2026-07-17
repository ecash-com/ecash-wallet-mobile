// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The decoded `wallet-endpoints/v1.json` payload (see `firebase/README.md`).
///
/// This carries **rotatable, non-consensus data only** — backend endpoints (and, later,
/// explorer/faucet/CoinNews URLs). Consensus/derivation params (coin-type, HRP, unit label,
/// network magic) are NEVER read from here; they stay in the app's compiled `NetworkRegistry`
/// (Golden Rule §1/§4). Decoding is lenient: unknown fields and unknown networks are ignored, so a
/// newer server payload never breaks an older app — and any decode failure yields `nil`, which the
/// caller treats as "keep the last-known-good / bundled endpoints" (graceful fallback).
struct RemoteEndpointConfig: Equatable, Sendable {
    /// The schema this app understands. A payload with a different `schemaVersion` is ignored.
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let refreshAfterSeconds: Int?
    let networks: [String: RemoteNetwork]

    struct RemoteNetwork: Equatable, Sendable {
        let backends: [RemoteBackend]
        let explorerTxTemplate: String?
        let services: RemoteServices?
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

    /// The primary backend per **known** `WalletNetwork`, ready to apply as remote defaults.
    /// - Network keys the app doesn't recognize are skipped (forward-compat).
    /// - Within a network, the lowest-`priority` backend with a valid kind + non-empty URL wins.
    /// - Only `electrum`/`esplora` kinds are accepted; anything else is ignored so a typo in the
    ///   config can never produce an unusable backend.
    func resolvedPrimaryBackends() -> [ResolvedBackend] {
        var result: [ResolvedBackend] = []
        for (key, network) in networks {
            guard let walletNetwork = WalletNetwork(rawValue: key) else { continue } // unknown → skip
            let candidates = network.backends
                .filter { Self.isValidKind($0.kind) && !$0.url.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
            guard let best = candidates.first else { continue }
            result.append(ResolvedBackend(network: walletNetwork,
                                          kind: best.kind,
                                          url: best.url.trimmingCharacters(in: .whitespaces)))
        }
        // Deterministic order (by rawValue) so callers/tests don't depend on dictionary iteration.
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// CoinNews indexer URL per **known** network that supplies a non-empty `services.coinnews.url`.
    /// Unknown networks and empty/missing URLs are skipped. Deterministic order by rawValue.
    func resolvedCoinNews() -> [ResolvedCoinNews] {
        var result: [ResolvedCoinNews] = []
        for (key, network) in networks {
            guard let walletNetwork = WalletNetwork(rawValue: key) else { continue }
            guard let url = Self.cleaned(network.services?.coinnews?.url) else { continue }
            result.append(ResolvedCoinNews(network: walletNetwork, url: url))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// Faucet config per **known** network that supplies a non-empty `services.faucet.url`.
    func resolvedFaucets() -> [ResolvedFaucet] {
        var result: [ResolvedFaucet] = []
        for (key, network) in networks {
            guard let walletNetwork = WalletNetwork(rawValue: key) else { continue }
            guard let url = Self.cleaned(network.services?.faucet?.url) else { continue }
            result.append(ResolvedFaucet(network: walletNetwork,
                                         url: url,
                                         amount: network.services?.faucet?.amount,
                                         cooldownSeconds: network.services?.faucet?.cooldownSeconds))
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

// MARK: - Codable (snake_case ↔ camelCase via explicit keys; extras ignored)

extension RemoteEndpointConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case refreshAfterSeconds = "refresh_after_seconds"
        case networks
    }
}

extension RemoteEndpointConfig.RemoteNetwork: Decodable {
    enum CodingKeys: String, CodingKey {
        case backends
        case explorerTxTemplate = "explorer_tx_template"
        case services
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
