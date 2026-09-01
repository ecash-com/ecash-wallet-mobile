// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Everything network-specific about a wallet, resolved in ONE place (Golden Rule §4).
/// Never hardcode any of these at a call site — go through `NetworkRegistry`.
public struct NetworkParams: Equatable, Sendable {
    /// BIP44 coin-type: 0' on mainnet, 1' on every test network.
    public let coinType: Int32
    /// Bech32 human-readable part for native segwit addresses (e.g. "bc", "tb").
    public let addressHRP: String
    /// Display unit label for amounts (e.g. "BTC", later "eCash").
    public let unitLabel: String
    /// Label for the smallest unit — "sat" on Bitcoin-family networks, **"szat"** on eCash ones.
    /// Used for fee rates ("3 szat/vB") and raw-amount displays. Network-derived rather than a
    /// constant precisely because the two must not be mixed: calling an eCash fee "sat/vB" borrows
    /// Bitcoin's unit for a different chain's money, which is the same class of error the network
    /// chip exists to prevent (Golden Rule §6). Append "s" for the plural at the call site.
    public let subUnitLabel: String
    /// Default Electrum/Esplora endpoint (overridable per network in Settings).
    public let defaultBackend: String
    /// Kind of the default backend — `"electrum"` (`ssl://`/`tcp://`) or `"esplora"`
    /// (`http(s)://`). Matches `WalletBackend.Kind`'s raw values. Lets a network default to
    /// Esplora (e.g. eCash) instead of assuming Electrum. A user override in Settings supersedes
    /// both this and `defaultBackend`.
    public let defaultBackendKind: String
    /// Explorer URL template; substitute "{txid}" for a transaction link.
    public let explorerTxTemplate: String
    /// Human-readable network name shown on the non-mainnet badge.
    public let displayName: String

    public init(coinType: Int32, addressHRP: String, unitLabel: String,
                subUnitLabel: String = "sat",
                defaultBackend: String, defaultBackendKind: String = "electrum",
                explorerTxTemplate: String, displayName: String) {
        self.coinType = coinType
        self.addressHRP = addressHRP
        self.unitLabel = unitLabel
        self.subUnitLabel = subUnitLabel
        self.defaultBackend = defaultBackend
        self.defaultBackendKind = defaultBackendKind
        self.explorerTxTemplate = explorerTxTemplate
        self.displayName = displayName
    }
}

/// Resolves a `WalletNetwork` to its parameters. Adding eCash later is a
/// new case here + a `WalletNetwork` case — not a refactor anywhere else.
public enum NetworkRegistry {
    /// Network params, with the **display name overlaid from the remote config** when one has been
    /// applied (`WalletManager.setRemoteDisplayName`).
    ///
    /// Why the overlay lives here rather than at the ~12 call sites: `.ecash` is a single case that
    /// points at whichever dry-run chain the config says (drynet2 → drynet3 → drynet4, matched by
    /// `family`). The backend and fork height already follow that rollover, but the NAME was baked
    /// into the binary — so after a rollover the app would sync drynet4 while every label in the UI
    /// still read "Drynet3". Substituting it in one place means the picker, the network chip, Receive
    /// warnings, Send review and the tx detail all follow automatically.
    public static func params(for network: WalletNetwork) -> NetworkParams {
        let base = bundledParams(for: network)
        guard let remote = WalletManager.remoteDisplayName(for: network), remote != base.displayName else {
            return base
        }
        return NetworkParams(coinType: base.coinType,
                             addressHRP: base.addressHRP,
                             unitLabel: base.unitLabel,
                             subUnitLabel: base.subUnitLabel,
                             defaultBackend: base.defaultBackend,
                             defaultBackendKind: base.defaultBackendKind,
                             explorerTxTemplate: base.explorerTxTemplate,
                             displayName: remote)
    }

    /// The values compiled into the app — the offline fallback, and everything except the name.
    static func bundledParams(for network: WalletNetwork) -> NetworkParams {
        switch network {
        case .bitcoin:
            return NetworkParams(
                coinType: Int32(0),
                addressHRP: "bc",
                unitLabel: "BTC",
                defaultBackend: "ssl://electrum.blockstream.info:50002",
                explorerTxTemplate: "https://mempool.space/tx/{txid}",
                displayName: "Bitcoin")
        case .signet:
            // The one network we run right now (Jake, 2026-06). Drivechain signet Electrum.
            // Fallbacks (from the L2L BlueWallet fork) for later rotation/Settings:
            //   ssl://signet-electrumx.wakiyamap.dev:50002 · ssl://electrum.emzy.de:53002
            return NetworkParams(
                coinType: Int32(1),
                addressHRP: "tb",
                unitLabel: "sBTC",
                // TLS endpoint — same electrs instance as :50001 (plaintext), just encrypted
                // transport (verified live: electrs/0.11.0, identical chain tip).
                defaultBackend: "ssl://node.signet.drivechain.info:50002",
                explorerTxTemplate: "https://explorer.signet.drivechain.info/tx/{txid}",
                displayName: "L2L Signet")
        case .ecash:
            // The eCash fork, currently the **drynet3** dry-run chain (drynet2 was decommissioned
            // 2026-07-23). Byte-identical to Bitcoin (mainnet `bc` HRP, coin-type `0'`) → BDK
            // `Network.bitcoin`; separated only by backend. Default backend is the public **Esplora**
            // (mempool-electrs) at the ROOT path (NO `/api` suffix). This is only the OFFLINE/first-
            // launch fallback — the live endpoint comes from the remote config (`drivechain.dev/config`,
            // `family: ecash`), which rotates across drynet ids without an app update.
            return NetworkParams(
                coinType: Int32(0),
                addressHRP: "bc",
                unitLabel: "ECX",
                subUnitLabel: "szat",
                defaultBackend: "https://esplora.drynet3.drivechain.dev",
                defaultBackendKind: "esplora",
                explorerTxTemplate: "https://explorer.drynet3.drivechain.dev/tx/{txid}",
                displayName: "Drynet3")
        case .thunder:
            // Thunder sidechain — ed25519/BLAKE3, NOT BDK. `coinType`/`addressHRP` are unused fillers
            // (the Thunder engine never derives via BDK). Unit is **ECX** — Thunder holds eCash value
            // (deposited from the eCash mainchain); thunder-rust itself uses `bitcoin::Amount`/₿ (it's
            // the generic sidechain template, no eCash branding), so the ECX label is ours.
            //
            // Backend is a **drivechain-esplora** index (github.com/octobocto/drivechain-esplora),
            // not the node's own JSON-RPC. The node keys its state by outpoint only, so an address
            // query there scans the whole UTXO table in memory, and it can answer no height, time or
            // fee for a transaction. The index answers all three from Postgres over the Esplora REST
            // shape. `kind: "thunder-esplora"` selects that wire layer; `"thunder"` still selects the
            // node RPC, which stays supported (docs/thunder-sidechain-support.md §8b).
            return NetworkParams(
                coinType: Int32(1),
                addressHRP: "",
                unitLabel: "ECX",
                // Thunder holds eCash value deposited from the eCash mainchain, so it's ECX-
                // denominated and takes eCash's sub-unit too.
                subUnitLabel: "szat",
                defaultBackend: "https://seed.alpha.ecash.eu.com/thunder",
                defaultBackendKind: "thunder-esplora",
                // No human-facing Thunder explorer exists yet; the index's own /tx route serves JSON,
                // which is still better than a link to a host that 404s. Swap this the moment one ships.
                explorerTxTemplate: "https://seed.alpha.ecash.eu.com/thunder/tx/{txid}",
                displayName: "Thunder")
        }
    }

    /// Convenience: the explorer URL for a given txid on a network.
    public static func explorerURL(for txid: String, on network: WalletNetwork) -> String {
        params(for: network).explorerTxTemplate.replacingOccurrences(of: "{txid}", with: txid)
    }

    /// The replay-protection `nLockTime` a network stamps on every tx it builds, or nil if none.
    ///
    /// **eCash** uses the reserved marker **`LOCKTIME_THRESHOLD - 1` = 499_999_999**
    /// (LayerTwo-Labs/bitcoin-patched#24): its patched consensus treats this value as *final* (like
    /// `nLockTime == 0`), while stock Bitcoin Core reads it as a block height ~500M blocks (~9,500
    /// years) out and rejects the tx as **non-final** — so an eCash tx carrying it confirms on eCash
    /// but can never replay onto Bitcoin. This is what makes an eCash spend safe for a holder who also
    /// has BTC at the same (byte-identical) addresses. NOTE: the marker only bites when at least one
    /// input is non-final (`nSequence < 0xFFFFFFFF`) — BDK's default RBF (`0xFFFFFFFD`) guarantees
    /// that. Bitcoin/Signet get nil (never stamp it — it would make their txs unminable). Internal:
    /// consumed only by `WalletEngine` at build time, never bridged.
    static func replayProtectionLockHeight(for network: WalletNetwork) -> UInt32? {
        switch network {
        case .ecash: return UInt32(499_999_999)   // LOCKTIME_THRESHOLD - 1
        case .bitcoin, .signet, .thunder: return nil
        }
    }

    /// The `nSequence` stamped on every input of a replay-protected tx.
    ///
    /// **This is load-bearing, not cosmetic.** Bitcoin only *enforces* `nLockTime` when at least one
    /// input is non-final (`nSequence < 0xFFFFFFFF`); if every input were final, Core ignores the
    /// locktime entirely and the eCash tx would replay onto Bitcoin after all — the exact thing the
    /// marker exists to prevent. BDK's RBF default (`0xFFFFFFFD`) already satisfies this, but relying
    /// on a library default for a money-safety property is how it gets silently removed later, so
    /// `WalletEngine` sets it explicitly. `0xFFFFFFFD` is the same value RBF uses, so this changes
    /// nothing about the transaction beyond making the guarantee ours.
    static let replayProtectionSequence: UInt32 = UInt32(0xFFFF_FFFD)

    /// The **fork height** for coin-splitting: coins confirmed BELOW this block are pre-fork (shared
    /// with the other chain → need splitting); at/above it, coins are chain-specific (post-fork, replay-
    /// safe). `.ecash` is **drynet3 → 957_600** today; the real eCash mainnet fork is block **964_000**
    /// (CLAUDE.md) — update this when `.ecash` moves from the dry-run to mainnet. nil where splitting
    /// doesn't apply (Bitcoin/Signet/Thunder). Internal: used by `WalletEngine.splitSummary`.
    static func forkHeight(for network: WalletNetwork) -> Int64? {
        switch network {
        case .ecash: return Int64(957_600)   // drynet3 (real eCash mainnet: 964_000)
        case .bitcoin, .signet, .thunder: return nil
        }
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
