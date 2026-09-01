// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// What one sync learned about a wallet.
struct ThunderScan {
    /// Spendable UTXOs across the scanned addresses. Withdrawal outputs are already filtered out —
    /// consensus refuses to let anyone spend one, and (on the Esplora path) its reported value folds
    /// the mainchain fee in, so it could not be reconstructed exactly anyway.
    let utxos: [ThunderPointedOutput]
    /// History rows. A row may carry `timestampEpochSeconds: nil` when the backend cannot date it;
    /// `ThunderService` fills those from its local first-seen record and re-sorts. Backends that know
    /// real block times leave nothing to fill.
    let transactions: [WalletTx]

    init(utxos: [ThunderPointedOutput], transactions: [WalletTx]) {
        self.utxos = utxos
        self.transactions = transactions
    }

    static let empty = ThunderScan(utxos: [], transactions: [])
}

/// The Thunder wire layer, behind one interface.
///
/// Two implementations, chosen per endpoint by `WalletBackend.Kind` (see `NetworkRegistry`):
///   * `ThunderRPCBackend` — the node's own JSON-RPC. Two calls per sync, but the node scans its whole
///     UTXO table to answer them and can report no height, time or fee, so history has to be inferred.
///   * `ThunderEsploraBackend` — a drivechain-esplora index. Per-address requests, but every row
///     arrives with a real height, time and fee.
///
/// The seam is deliberately narrow: **address derivation, coin selection, Borsh encoding, signing and
/// the submitted JSON are identical on both paths**, so which backend is in use can never change what
/// gets signed. Only where the facts come from changes.
///
/// `Sendable` so `ThunderService` (a `@MainActor` type) can hand it to an `await` without dragging
/// decoding onto the main actor — the same reason the two clients are `Sendable` structs.
protocol ThunderBackend: Sendable {
    /// Which of these addresses the chain has ever seen — the gap-limit discovery probe.
    ///
    /// Returns **nil** from a backend with no cheap way to answer, which means "don't extend the
    /// window". The node RPC is that case: it takes the whole address set in one call and scans its
    /// UTXO table, so asking it repeatedly to discover a window would cost a full scan per batch.
    func usedAddresses(_ addresses: [String]) async throws -> [String]?

    /// Everything a sync needs: spendable UTXOs plus history, for the given address window.
    ///
    /// `knownUsed` is the discovery probe's result for exactly these addresses, so a backend that
    /// would otherwise probe them itself can skip straight to fetching. Passing nil means "find out
    /// yourself". Getting this wrong under-reports rather than over-reports — an address wrongly
    /// omitted loses its coins from the balance — so only ever pass a result for the same window.
    func scan(addresses: [String], knownUsed: [String]?) async throws -> ThunderScan

    /// Just the spendable UTXOs — what the send path needs, without paying for history.
    func spendableUTXOs(addresses: [String]) async throws -> [ThunderPointedOutput]

    /// Submit a signed transaction; returns its txid. Both backends put the identical JSON on the
    /// wire (the Esplora index relays `POST /tx` into `submit_transaction` unchanged).
    func submit(_ authorized: AuthorizedThunderTransaction) async throws -> String
}

/// Builds the backend a resolved endpoint calls for.
///
/// The kind string comes from `WalletManager.backendKind(for: .thunder)`, which resolves the user's
/// Settings override, then any remote default, then the bundled `NetworkRegistry` value — so a user
/// pointing the app at a bare Thunder node with no index in front of it still works, and gets the
/// node-RPC path automatically.
enum ThunderBackendFactory {
    static func make(kind: String, url: String) -> ThunderBackend {
        switch kind {
        case "thunder":
            return ThunderRPCBackend(client: ThunderRPCClient(endpoint: url))
        case "thunder-esplora":
            return ThunderEsploraBackend(client: ThunderEsploraClient(endpoint: url))
        default:
            // An unrecognised kind means stale or hand-edited config. The index is the registry
            // default and the strictly more capable path, so fall there rather than refusing to sync.
            return ThunderEsploraBackend(client: ThunderEsploraClient(endpoint: url))
        }
    }
}
