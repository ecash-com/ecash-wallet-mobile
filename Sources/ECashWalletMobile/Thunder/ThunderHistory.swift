// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// Rebuilds a wallet's transaction history from the two address-scoped reads the node offers.
///
/// **Why it has to be reconstructed at all:** Thunder has no address-scoped history RPC. `get_utxos`
/// returns only *unspent* outputs, so on its own every payment the user ever made is invisible.
/// `get_stxos` supplies the other half — outputs of ours that have since been spent, each tagged with
/// the `InPoint` naming the transaction that took it. Together they cover every coin that ever
/// touched our addresses, which is enough to derive each transaction's net effect:
///
///   received(txid) = value of outputs that txid created for us   (from the outpoint)
///   spent(txid)    = value of our outputs that txid consumed     (from the inpoint)
///   net(txid)      = received − spent
///
/// **What we deliberately cannot fill in.** The node exposes no height for a transaction — `Header`
/// carries no height field, `get_block` doesn't return one, and `getblockcount` gives only the tip —
/// so there is no cheap txid → height mapping. That costs us real confirmation depth and true
/// chronological order. Rather than invent either:
///   * `blockHeight` is left **nil** while `confirmations` is 1, a combination the UI reads as
///     "confirmed, depth unknown" and renders without a count or a date. Anything appearing in
///     `get_utxos`/`get_stxos` is by definition in the node's *state*, which only reflects connected
///     blocks — so it is confirmed, at least one deep. 1 is a truthful floor, not a guess.
///   * ordering falls back to when we first observed each txid (`firstSeen`), which is right for a
///     wallet in daily use and arbitrary-but-stable for a freshly restored one.
/// Both go away the moment the node reports a height per transaction.
enum ThunderHistory {

    /// One coin's worth of evidence, in whichever direction it points.
    struct Entry: Equatable {
        let txid: String        // the transaction this evidence is about
        let sats: Int64         // positive = it paid us, negative = it spent from us
    }

    /// Build the wallet's transactions from its unspent and spent outputs.
    ///
    /// Entries whose transaction we can't name — coinbase and mainchain-deposit outpoints, and
    /// withdrawal inpoints — are skipped rather than attributed to a fabricated txid.
    ///
    /// `firstSeen` supplies the ordering key per txid (epoch seconds); a txid absent from it sorts
    /// oldest. It defaults to empty because `ThunderService` now applies that stamping uniformly to
    /// any row *any* backend couldn't date, so this builder no longer has to know about it — the
    /// parameter stays for the tests that assert the ordering rule directly.
    static func build(utxos: [ThunderRPCPointedOutput],
                      stxos: [ThunderRPCPointedSpentOutput],
                      firstSeen: [String: Int64] = [:]) -> [WalletTx] {
        var received: [String: Int64] = [:]
        var spent: [String: Int64] = [:]

        // Every output ever paid to us — still unspent, plus those since spent.
        for utxo in utxos {
            guard let txid = creatingTxid(utxo.outpoint.outPoint) else { continue }
            received[txid, default: 0] += Int64(clamping: utxo.output.content.valueSats)
        }
        for stxo in stxos {
            if let txid = creatingTxid(stxo.outpoint.outPoint) {
                received[txid, default: 0] += Int64(clamping: stxo.output.output.content.valueSats)
            }
            // …and the transaction that took it away.
            if case let .regular(txidBytes, _) = stxo.output.inpoint {
                let txid = ThunderHex.encode(txidBytes)
                spent[txid, default: 0] += Int64(clamping: stxo.output.output.content.valueSats)
            }
            // `.withdrawal` inpoints left out on purpose: a withdrawal bundle is not a Thunder tx and
            // has no txid to attribute the spend to. Showing it as an unexplained outflow would be
            // worse than omitting it until withdrawals are actually supported (v2).
        }

        let txids = Set(received.keys).union(spent.keys)
        let txs = txids.map { txid -> WalletTx in
            let inbound = received[txid] ?? 0
            let outbound = spent[txid] ?? 0
            return WalletTx(txid: txid,
                            netSats: inbound - outbound,
                            // Fee isn't derivable: it's value_in − value_out over the WHOLE tx, and we
                            // only see the parts involving our addresses.
                            feeSats: nil,
                            confirmations: 1,               // in the node's state ⇒ at least 1 block deep
                            timestampEpochSeconds: firstSeen[txid],
                            isRBF: false,                   // Thunder has no RBF
                            blockHeight: nil,               // unknown — see the type note
                            vsize: nil,
                            coinNewsKind: nil,
                            receivedSats: inbound)
        }
        // Newest-first by whatever ordering key we have; unknown sorts last.
        return txs.sorted { ($0.timestampEpochSeconds ?? 0) > ($1.timestampEpochSeconds ?? 0) }
    }

    /// The Thunder txid that created this output, or nil when it wasn't a Thunder transaction —
    /// a coinbase (created by a block body) or a mainchain deposit (created by a Bitcoin tx).
    private static func creatingTxid(_ outPoint: ThunderOutPoint) -> String? {
        switch outPoint {
        case let .regular(txid, _): return ThunderHex.encode(txid)
        case .coinbase, .deposit: return nil
        }
    }
}
