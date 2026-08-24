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
/// cases (`RemoteNetwork.walletNetwork`): `bitcoin`/`signet` by **`id`** (both report
/// `family: "bitcoin"`, so `family` can't tell them apart), and the eCash test net by
/// **`family: "ecash"`** because it's served under rotating ids (`drynet2` → `drynet3` → …). Unknown
/// entries are skipped (forward-compat). When two entries map to the same network during a rollover,
/// the first one with a usable value wins — a decommissioned entry with empty backends never shadows
/// the live one.
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
        /// Block height at which this chain forked from Bitcoin — coins confirmed BELOW it exist on
        /// both chains and need splitting (`SplitSummary.classify`). Null for chains that never
        /// forked (Bitcoin, Signet). Carried remotely because it CHANGES per dry-run: drynet2/3 use
        /// 957_600, drynet4 uses 961_632. Without this, a config-driven rollover to a new drynet
        /// would silently classify against the previous fork height and mis-flag every coin
        /// confirmed between the two.
        let forkHeight: Int64?
        /// Human-readable name for this chain ("Drynet 3", "Drynet 4"). Carried remotely for the same
        /// reason as `forkHeight`: `.ecash` follows whichever drynet the config points at, so a name
        /// baked into the binary goes stale at the next rollover.
        let displayName: String?

        /// The `WalletNetwork` this entry maps to, or nil if unknown to this app.
        /// - `bitcoin` / `signet` (and a future literal `ecash`) match a `WalletNetwork` rawValue by
        ///   **`id`** — `family` can't identify these because Bitcoin mainnet and Signet BOTH report
        ///   `family: "bitcoin"` (server change 2026-07-19).
        /// - The eCash test net is served under **rotating ids** (`drynet2` → `drynet3` → …) that all
        ///   share `family: "ecash"`, which uniquely identifies OUR `.ecash` network. Mapping it by
        ///   `family` (not a hardcoded id alias) means each drynet rollover Just Works with no app
        ///   change — the old `drynet2`-only alias silently dropped `drynet3` (2026-07-23 bug).
        var walletNetwork: WalletNetwork? {
            if let id, let known = WalletNetwork(rawValue: id) { return known }
            // The eCash dry-run net rotates ids (`drynet2` → `drynet3` → …), all `family: "ecash"`.
            // Match either — `family` is the clean signal; the `drynet` id prefix is a belt-and-
            // suspenders fallback so an entry that omits `family` still resolves.
            if family == "ecash" || (id?.hasPrefix("drynet") ?? false) { return .ecash }
            return nil
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

    struct ResolvedForkHeight: Equatable, Sendable {
        let network: WalletNetwork
        let height: Int64
    }

    struct ResolvedDisplayName: Equatable, Sendable {
        let network: WalletNetwork
        let name: String
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
    // Each resolver maps entries to a `WalletNetwork` (see `walletNetwork`), skips unknown networks,
    // and returns a deterministic order (by rawValue). When two entries map to the SAME network — as
    // `drynet2` and `drynet3` both do (`.ecash`) during a rollover — the first entry that actually
    // yields a usable value wins: `seen` is claimed only AFTER a value is found, so a decommissioned
    // entry with empty backends (drynet2 today) doesn't shadow the live one (drynet3).

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
            guard let walletNetwork = network.walletNetwork, !seen.contains(walletNetwork.rawValue) else { continue }
            let best = network.backends.enumerated()
                .filter { Self.isValidKind($0.element.kind) && !$0.element.url.trimmingCharacters(in: .whitespaces).isEmpty }
                .min { lhs, rhs in
                    let lp = lhs.element.priority ?? Int.max
                    let rp = rhs.element.priority ?? Int.max
                    return lp != rp ? lp < rp : lhs.offset < rhs.offset   // tie → array order
                }?.element
            guard let best else { continue }   // no usable backend (e.g. decommissioned drynet2) → don't claim
            seen.insert(walletNetwork.rawValue)
            result.append(ResolvedBackend(network: walletNetwork,
                                          kind: best.kind,
                                          url: best.url.trimmingCharacters(in: .whitespaces)))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// CoinNews indexer URL per **known** network that supplies a non-empty `services.coinnews.url`.
    /// Every network's **Esplora** URL, regardless of which backend won `resolvedPrimaryBackends()`.
    ///
    /// Those two answer different questions. "Which backend syncs this network's wallets?" is a
    /// priority decision that can legitimately land on Electrum. "Where can we ask an HTTP question
    /// about an outpoint?" needs Esplora specifically — the split check is HTTP-only. Keeping just
    /// the primary threw the Esplora URL away whenever Electrum outranked it, which silently
    /// disabled the split check on somebody else's config change.
    func resolvedEsploraEndpoints() -> [ResolvedBackend] {
        var result: [ResolvedBackend] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, !seen.contains(walletNetwork.rawValue) else { continue }
            let esplora = network.backends
                .filter { $0.kind == "esplora" }
                .map { $0.url.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            guard let esplora else { continue }
            seen.insert(walletNetwork.rawValue)
            result.append(ResolvedBackend(network: walletNetwork, kind: "esplora", url: esplora))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    func resolvedCoinNews() -> [ResolvedCoinNews] {
        var result: [ResolvedCoinNews] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, !seen.contains(walletNetwork.rawValue) else { continue }
            guard let url = Self.cleaned(network.services?.coinnews?.url) else { continue }
            seen.insert(walletNetwork.rawValue)
            result.append(ResolvedCoinNews(network: walletNetwork, url: url))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// Faucet config per **known** network that supplies a non-empty `services.faucet.url`.
    func resolvedFaucets() -> [ResolvedFaucet] {
        var result: [ResolvedFaucet] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, !seen.contains(walletNetwork.rawValue) else { continue }
            guard let url = Self.cleaned(network.services?.faucet?.url) else { continue }
            seen.insert(walletNetwork.rawValue)
            result.append(ResolvedFaucet(network: walletNetwork,
                                         url: url,
                                         amount: network.services?.faucet?.amount,
                                         cooldownSeconds: network.services?.faucet?.cooldownSeconds))
        }
        return result.sorted { $0.network.rawValue < $1.network.rawValue }
    }

    /// Explorer tx-URL template per **known** network that supplies a non-empty, `{txid}`-bearing
    /// `explorer_tx_template`. A template without the `{txid}` placeholder is rejected.
    /// Fork height per network, taken from **the same entry that won `resolvedPrimaryBackends`**.
    ///
    /// This has to match, and matching is not automatic: several entries map to `.ecash` (drynet2,
    /// drynet3, drynet4 all report `family: "ecash"`). Backend selection is FIRST-wins among entries
    /// that actually have a usable backend, so a decommissioned drynet2 is skipped and drynet3 wins.
    /// A naive loop that just applied every fork height would let the LAST entry win — drynet4's
    /// 961_632 — while the app was still talking to drynet3 (957_600), and every coin confirmed
    /// between those heights would be wrongly flagged as needing a split. Height and backend must
    /// come from one entry or the classification describes a chain we aren't on.
    func resolvedForkHeights() -> [ResolvedForkHeight] {
        var out: [ResolvedForkHeight] = []
        var seen: Set<String> = []
        for n in networks {
            guard let network = n.walletNetwork, !seen.contains(network.rawValue) else { continue }
            guard Self.hasUsableBackend(n) else { continue }   // same skip as backend selection
            seen.insert(network.rawValue)
            guard let height = n.forkHeight, height > 0 else { continue }
            out.append(ResolvedForkHeight(network: network, height: height))
        }
        return out
    }

    /// Display name per network, from the SAME entry that won backend selection — same pairing rule
    /// as `resolvedForkHeights`, and for the same reason: labelling the UI with one chain's name
    /// while syncing another is exactly the confusion this is meant to remove.
    func resolvedDisplayNames() -> [ResolvedDisplayName] {
        var out: [ResolvedDisplayName] = []
        var seen: Set<String> = []
        for n in networks {
            guard let network = n.walletNetwork, !seen.contains(network.rawValue) else { continue }
            guard Self.hasUsableBackend(n) else { continue }
            seen.insert(network.rawValue)
            guard let name = n.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            out.append(ResolvedDisplayName(network: network, name: name))
        }
        return out
    }

    /// Whether an entry offers a backend we could actually use — the gate that decides which of the
    /// several `.ecash` entries is the live one.
    private static func hasUsableBackend(_ n: RemoteNetwork) -> Bool {
        n.backends.contains { isValidKind($0.kind) && !$0.url.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func resolvedExplorers() -> [ResolvedExplorer] {
        var result: [ResolvedExplorer] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, !seen.contains(walletNetwork.rawValue) else { continue }
            guard let template = Self.cleaned(network.explorerTxTemplate), template.contains("{txid}") else { continue }
            seen.insert(walletNetwork.rawValue)
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
        case forkHeight = "fork_height"
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? c.decodeIfPresent(String.self, forKey: .id)
        self.family = try? c.decodeIfPresent(String.self, forKey: .family)
        // `backends` may be absent for a network that only lists services — default to empty.
        self.backends = (try? c.decode([RemoteEndpointConfig.RemoteBackend].self, forKey: .backends)) ?? []
        self.explorerTxTemplate = try? c.decodeIfPresent(String.self, forKey: .explorerTxTemplate)
        self.services = try? c.decodeIfPresent(RemoteEndpointConfig.RemoteServices.self, forKey: .services)
        self.forkHeight = (try? c.decodeIfPresent(Int64.self, forKey: .forkHeight)) ?? nil
        self.displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
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
