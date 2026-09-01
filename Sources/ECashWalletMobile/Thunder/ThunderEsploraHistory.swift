// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Turns indexed transactions into wallet history.
///
/// **The contrast with `ThunderHistory` is the whole point of the Esplora path.** That builder has to
/// *infer* each transaction from unspent-vs-spent evidence about our own coins, and its type comment
/// lists what it therefore cannot know: no fee, no height, no real confirmation depth, and an ordering
/// borrowed from when this device happened to first see each txid. Here every one of those arrives as
/// a fact:
///
///   * `fee` is the transaction's own, computed by the index over the whole transaction — not just the
///     parts touching us, which is precisely why the RPC path can't compute it.
///   * `status.block_height` + the chain tip give a true confirmation count.
///   * `status.block_time` is a real timestamp, so ordering is chronological rather than local.
///   * `vin[].prevout` names what each input spent, so the outgoing side is read rather than deduced.
///
/// The arithmetic is the ordinary wallet one: sum the outputs that pay us, subtract the inputs that
/// spent from us. `ours` is the address window, so "ours" means "an address this wallet derives".
enum ThunderEsploraHistory {

    /// Build history rows from indexed transactions.
    ///
    /// - Parameters:
    ///   - txs: transactions touching this wallet, in any order and possibly with duplicates (the same
    ///     transaction is returned by every address of ours it touches — a send from two of our coins
    ///     to a third of our addresses appears three times). Deduplicated here by txid.
    ///   - ours: the wallet's address window, base58.
    ///   - tipHeight: the indexed tip, for confirmation depth.
    static func build(txs: [ThunderEsploraTx], ours: Set<String>, tipHeight: Int64) -> [WalletTx] {
        var seen = Set<String>()
        var out: [WalletTx] = []
        for tx in txs where !seen.contains(tx.txid) {
            seen.insert(tx.txid)
            out.append(row(tx: tx, ours: ours, tipHeight: tipHeight))
        }
        // Newest first: by height, then by time for two in the same block. A row the index somehow
        // left undated sorts oldest rather than jumping to the top.
        return out.sorted { lhs, rhs in
            let lh = lhs.blockHeight ?? -1, rh = rhs.blockHeight ?? -1
            if lh != rh { return lh > rh }
            return (lhs.timestampEpochSeconds ?? 0) > (rhs.timestampEpochSeconds ?? 0)
        }
    }

    private static func row(tx: ThunderEsploraTx, ours: Set<String>, tipHeight: Int64) -> WalletTx {
        // Everything this transaction paid to an address of ours. Withdrawal outputs are counted at
        // their reported value (payout + mainchain fee): unlike the spending path, history is
        // describing what left the sidechain, and both halves did.
        var received: Int64 = 0
        for vout in tx.vout where ours.contains(vout.scriptPubKeyAddress) {
            received += vout.value
        }
        // …and everything it spent from us. A coinbase input has no prevout to attribute.
        var spent: Int64 = 0
        for vin in tx.vin where !vin.isCoinbase {
            guard let prevout = vin.prevout, ours.contains(prevout.scriptPubKeyAddress) else { continue }
            spent += prevout.value
        }

        return WalletTx(txid: tx.txid,
                        netSats: received - spent,
                        // The index computes the fee over the whole transaction, so unlike the RPC
                        // path this is the real one — but only a transaction we funded actually paid
                        // it. Attributing a stranger's fee to a receive would misreport it.
                        feeSats: spent > 0 ? tx.fee : nil,
                        confirmations: tx.status.confirmations(tipHeight: tipHeight),
                        timestampEpochSeconds: tx.status.blockTime,
                        isRBF: false,                       // Thunder has no RBF
                        blockHeight: tx.status.blockHeight,
                        // The index reports weight as exactly size × 4, so the Borsh size IS the
                        // divisor a fee rate wants. Zero means the index didn't say.
                        vsize: tx.size > 0 ? tx.size : nil,
                        coinNewsKind: nil,                  // CoinNews is Bitcoin/eCash only
                        // Carries a self-transfer, where `netSats` is only the fee and the amount that
                        // actually moved would otherwise appear nowhere (see `WalletTx.receivedSats`).
                        receivedSats: received)
    }
}
