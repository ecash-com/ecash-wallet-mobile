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
/// cases by an explicit allow-list of **`id`s** (`RemoteNetwork.walletNetwork`). Unknown ids are
/// skipped, never guessed at, which is what keeps a new network (the real eCash fork) from being
/// routed onto an existing one's wallets. When two entries map to the same network during a rollover,
/// the first one with a usable value wins — a decommissioned entry with empty backends never shadows
/// the live one.
struct RemoteEndpointConfig: Equatable, Sendable {
    /// The schema this app understands. A payload with a different `schemaVersion` is ignored.
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let refreshAfterSeconds: Int?
    let networks: [RemoteNetwork]
    /// Which network the Dashboard tab reports on (`docs/dashboard-plan.md` §4.6). Absent → betanet.
    let dashboard: RemoteDashboard?

    /// `{"network_id": "betanet", "display_name": "Betanet", "explorer_url": "https://…",
    /// "releases_channel": "betanet"}`. Display data only: it never routes a wallet (that's
    /// `walletNetwork`'s allow-list), so a free-form id is safe here.
    struct RemoteDashboard: Equatable, Sendable {
        let networkId: String?
        let displayName: String?
        let explorerURL: String?
        let releasesChannel: String?
    }

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

        /// The `WalletNetwork` this entry maps to, or nil if this app doesn't know it.
        ///
        /// **An explicit allow-list of ids, and nothing else.** An entry this build doesn't
        /// recognise is IGNORED, never guessed at. The mapping used to guess in two ways, and both
        /// landed on `.ecash`, which is **alphanet**:
        /// - matching the id against `WalletNetwork.rawValue`, where `.ecash`'s raw value is
        ///   `"ecash"`, the most natural id for the real fork;
        /// - a `family: "ecash"` fallback for unrecognised ids.
        ///
        /// Either one meant publishing the real eCash fork under a new id would repoint every
        /// installed app's alphanet wallets at the real fork's backends and fork height, with no app
        /// update involved (`docs/real-ecash-fork-transition.md` §0). A wallet's network is
        /// persisted; only an app that knows about a network may route wallets to it.
        ///
        /// `family` can't identify a network anyway: Bitcoin and Signet both report `"bitcoin"`, and
        /// alphanet and betanet both report `"ecash"` (the 2026-09-17 bug where betanet was
        /// swallowed by alphanet).
        ///
        /// Adding a network: add its case to `WalletNetwork` and its id here, in the same change.
        var walletNetwork: WalletNetwork? {
            guard let id else { return nil }
            return Self.walletNetwork(forId: id)
        }

        /// The allow-list itself, by id — shared with `DashboardNetwork.walletNetwork`.
        static func walletNetwork(forId id: String) -> WalletNetwork? {
            switch id {
            case "bitcoin": return .bitcoin
            case "signet": return .signet
            case "alphanet": return .ecash
            case "betanet": return .ecashBeta
            default:
                // The dry runs before alphanet were published under rotating ids (drynet2 → 3 → 4),
                // all of which were `.ecash`. Kept so an old payload still resolves; no new
                // network will ever use this prefix.
                if id.hasPrefix("drynet") { return .ecash }
                return nil
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
        /// The network's hosted BIP300 enforcer (`services.enforcer.url`). BitWindow's own catalog
        /// carries this field; the published config doesn't yet, so today it's always nil and
        /// `EnforcerEndpointRegistry`'s bundled default applies.
        let enforcer: RemoteService?
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

    /// A BIP300 enforcer URL resolved to a known `WalletNetwork`.
    struct ResolvedEnforcer: Equatable, Sendable {
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

    /// The dashboard's network, or nil when the config doesn't name one usably — the caller keeps
    /// the bundled betanet. Needs an id and an http(s) explorer URL; the name and releases channel
    /// default to the id.
    func resolvedDashboardNetwork() -> DashboardNetwork? {
        guard let d = dashboard,
              let id = Self.cleaned(d.networkId),
              let explorer = Self.cleaned(d.explorerURL),
              explorer.hasPrefix("https://") || explorer.hasPrefix("http://") else { return nil }
        return DashboardNetwork(id: id,
                                displayName: Self.cleaned(d.displayName) ?? id,
                                explorerURL: explorer,
                                releasesChannel: Self.cleaned(d.releasesChannel) ?? id)
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

    /// BIP300 enforcer URL per **known** network that supplies a non-empty `services.enforcer.url`.
    func resolvedEnforcers() -> [ResolvedEnforcer] {
        var result: [ResolvedEnforcer] = []
        var seen: Set<String> = []
        for network in networks {
            guard let walletNetwork = network.walletNetwork, !seen.contains(walletNetwork.rawValue) else { continue }
            guard let url = Self.cleaned(network.services?.enforcer?.url) else { continue }
            seen.insert(walletNetwork.rawValue)
            result.append(ResolvedEnforcer(network: walletNetwork, url: url))
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
        case networks, dashboard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.refreshAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshAfterSeconds)
        self.networks = try c.decode([RemoteNetwork].self, forKey: .networks)
        // Lenient: a malformed `dashboard` block must not cost the app its backends.
        self.dashboard = (try? c.decodeIfPresent(RemoteDashboard.self, forKey: .dashboard)) ?? nil
    }
}

extension RemoteEndpointConfig.RemoteDashboard: Decodable {
    enum CodingKeys: String, CodingKey {
        case networkId = "network_id"
        case displayName = "display_name"
        case explorerURL = "explorer_url"
        case releasesChannel = "releases_channel"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.networkId = (try? c.decodeIfPresent(String.self, forKey: .networkId)) ?? nil
        self.displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        self.explorerURL = (try? c.decodeIfPresent(String.self, forKey: .explorerURL)) ?? nil
        self.releasesChannel = (try? c.decodeIfPresent(String.self, forKey: .releasesChannel)) ?? nil
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
        case faucet, coinnews, enforcer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.faucet = try? c.decodeIfPresent(RemoteEndpointConfig.RemoteFaucet.self, forKey: .faucet)
        self.coinnews = try? c.decodeIfPresent(RemoteEndpointConfig.RemoteService.self, forKey: .coinnews)
        self.enforcer = try? c.decodeIfPresent(RemoteEndpointConfig.RemoteService.self, forKey: .enforcer)
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
