// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The `ThunderBackend` backed by the node's own JSON-RPC — the original thin-node flow
/// (docs/thunder-sidechain-support.md §8b).
///
/// Kept as a first-class option, not as legacy: it needs nothing but a node, so it still works against
/// a Thunder instance nobody has stood an index in front of. What it cannot do is date a transaction —
/// the node exposes no per-tx height — which is why every row it produces carries a nil timestamp for
/// `ThunderService` to fill from its local first-seen record. See `ThunderHistory` for the rest of what
/// this path can and can't derive.
struct ThunderRPCBackend: ThunderBackend {
    let client: ThunderRPCClient

    init(client: ThunderRPCClient) { self.client = client }

    /// Always nil — see `ThunderBackend.usedAddresses`. `get_utxos` reads the whole UTXO table per
    /// call, so probing batch by batch would cost a full scan each time. A wallet on this backend keeps
    /// the fixed `revealed + gap limit` window it has always had.
    func usedAddresses(_ addresses: [String]) async throws -> [String]? { nil }

    func scan(addresses: [String], knownUsed: [String]?) async throws -> ThunderScan {
        let utxos = try await client.getUtxos(addresses: addresses)
        // Spent outputs are the other half of history; a node without get_stxos still gives a correct
        // balance, so a failure here must not break syncing.
        let stxos = (try? await client.getStxos(addresses: addresses)) ?? []
        return ThunderScan(utxos: utxos.compactMap(\.spendable),
                           transactions: ThunderHistory.build(utxos: utxos, stxos: stxos))
    }

    func spendableUTXOs(addresses: [String]) async throws -> [ThunderPointedOutput] {
        try await client.getUtxos(addresses: addresses).compactMap(\.spendable)
    }

    func submit(_ authorized: AuthorizedThunderTransaction) async throws -> String {
        try await client.submitTransaction(authorized)
    }
}
