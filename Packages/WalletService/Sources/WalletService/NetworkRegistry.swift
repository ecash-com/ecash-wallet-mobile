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
    /// Default Electrum/Esplora endpoint (overridable per network in Settings).
    public let defaultBackend: String
    /// Explorer URL template; substitute "{txid}" for a transaction link.
    public let explorerTxTemplate: String
    /// Human-readable network name shown on the non-mainnet badge.
    public let displayName: String

    public init(coinType: Int32, addressHRP: String, unitLabel: String,
                defaultBackend: String, explorerTxTemplate: String, displayName: String) {
        self.coinType = coinType
        self.addressHRP = addressHRP
        self.unitLabel = unitLabel
        self.defaultBackend = defaultBackend
        self.explorerTxTemplate = explorerTxTemplate
        self.displayName = displayName
    }
}

/// Resolves a `WalletNetwork` to its parameters. Adding eCash later is a
/// new case here + a `WalletNetwork` case — not a refactor anywhere else.
public enum NetworkRegistry {
    public static func params(for network: WalletNetwork) -> NetworkParams {
        switch network {
        case .bitcoin:
            return NetworkParams(
                coinType: Int32(0),
                addressHRP: "bc",
                unitLabel: "BTC",
                defaultBackend: "ssl://electrum.blockstream.info:50002",
                explorerTxTemplate: "https://mempool.space/tx/{txid}",
                displayName: "Bitcoin")
        case .testnet4:
            // Public Testnet4 Electrum servers. Default = mempool.space (well-maintained,
            // VERIFIED syncing via bdk's ElectrumClient on the host, 2026-06-11). Fallbacks for the
            // planned server rotation / Settings override — ✓ = verified syncing, ✗ = failed when checked:
            // ✓ ssl://blackie.c3-soft.com:57010 ✓ tcp://blackie.c3-soft.com:57009
            // ✗ ssl://testnet4.qtornado.com:51012 (AllAttemptsErrored) ✗ :51011 (handshake)
            // ✗ ssl://fulcrum.theuplink.net:60002 ✗ ssl://bitcoin.stagemole.eu:5010
            // (untested, from Jake's list) ssl://13.212.194.61:60002, ssl://134.199.227.217:50002,
            // ssl://v22019051929289916.bestsrv.de:60002
            return NetworkParams(
                coinType: Int32(1),
                addressHRP: "tb",
                unitLabel: "tBTC",
                defaultBackend: "ssl://mempool.space:40002",
                explorerTxTemplate: "https://mempool.space/testnet4/tx/{txid}",
                displayName: "Testnet4")
        case .signet:
            // The one network we run right now (Jake, 2026-06). Drivechain signet Electrum.
            // Fallbacks (from the L2L BlueWallet fork) for later rotation/Settings:
            //   ssl://signet-electrumx.wakiyamap.dev:50002 · ssl://electrum.emzy.de:53002
            return NetworkParams(
                coinType: Int32(1),
                addressHRP: "tb",
                unitLabel: "sBTC",
                defaultBackend: "tcp://node.signet.drivechain.info:50001",
                explorerTxTemplate: "https://explorer.signet.drivechain.info/tx/{txid}",
                displayName: "Signet")
        case .regtest:
            return NetworkParams(
                coinType: Int32(1),
                addressHRP: "bcrt",
                unitLabel: "rBTC",
                defaultBackend: "tcp://127.0.0.1:50000",
                explorerTxTemplate: "http://127.0.0.1/tx/{txid}",
                displayName: "Regtest")
        }
    }

    /// Convenience: the explorer URL for a given txid on a network.
    public static func explorerURL(for txid: String, on network: WalletNetwork) -> String {
        params(for: network).explorerTxTemplate.replacingOccurrences(of: "{txid}", with: txid)
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
