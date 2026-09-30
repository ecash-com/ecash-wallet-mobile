// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The result of choosing which UTXOs to spend: the inputs, what goes back to us as change, and the
/// fee those two imply. In Thunder the fee is **implicit** — `value_in - value_out` — so `feeSats` is
/// not a field we put in the transaction; it's the gap we must leave between them.
struct ThunderCoinSelection: Equatable {
    let inputs: [ThunderPointedOutput]
    let changeSats: UInt64
    let feeSats: UInt64

    var totalInputSats: UInt64 { inputs.reduce(0) { $0 &+ $1.valueSats } }
}

/// Coin selection for Thunder sends. Runs entirely on the phone — the node serves UTXOs and relays,
/// it does not select (the flow agreed with the Thunder dev, docs §8b).
///
/// **Fee model.** Thunder's consensus check is only `value_in >= value_out`
/// (`State::validate_filled_transaction` → `NotEnoughValueIn`); there is no min-relay floor and no
/// vbyte/weight concept. So we price the fee off the transaction's canonical Borsh size — every field
/// is fixed-width, so the size is known exactly before the tx is built — times the requested sat/byte,
/// with a 1-sat floor so we never submit a free transaction that miners have no reason to include.
enum ThunderCoinSelector {
    /// Never emit a zero-fee transaction, whatever the rate rounds to.
    static let minimumFeeSats: UInt64 = 1

    /// Fee for a transaction of `inputCount` inputs and `outputCount` plain value outputs.
    static func fee(inputCount: Int, outputCount: Int, satPerByte: UInt64) -> UInt64 {
        let contents = [ThunderOutputContent](repeating: .value(sats: 0), count: outputCount)
        let size = UInt64(ThunderTransaction.borshSize(inputCount: inputCount, outputs: contents))
        return max(minimumFeeSats, size &* satPerByte)
    }

    /// Select coins to pay `targetSats` plus fee, **locking as little of the balance as possible.**
    ///
    /// Why that's the goal on Thunder: a coin created by an unconfirmed transaction — including our own
    /// change — can't be spent until the next Thunder block (the node validates spends against a utreexo
    /// accumulator that only holds confirmed coins). Every coin a send consumes is therefore unavailable
    /// until the block after, change included. Spending the biggest coin for a small payment (what this
    /// used to do) parks most of the balance for a block; spending the smallest adequate coin leaves the
    /// rest free for another send in the same block.
    ///
    /// 1. The **smallest single coin** that covers payment + fee on its own.
    /// 2. Otherwise coins **smallest-first** until they cover it — thunder-rust's own wallet rule
    ///    (`Wallet::select_coins`), which BitWindow gets through the node.
    ///
    /// The cost is occasionally more inputs (a larger fee) than largest-first would use; at Thunder's
    /// fee rates that's a few hundred sats against a whole block of waiting.
    ///
    /// If the leftover change is worth less than the output it would occupy, it is dropped into the fee
    /// instead of creating a UTXO that costs more to spend than it holds.
    static func select(utxos: [ThunderPointedOutput],
                       targetSats: UInt64,
                       satPerByte: UInt64) throws -> ThunderCoinSelection {
        let available = utxos.reduce(UInt64(0)) { $0 &+ $1.valueSats }
        // Smallest first; ties broken by the coin's hash so the choice is deterministic.
        let ascending = utxos.map { ($0, $0.utxoHash()) }.sorted { lhs, rhs in
            lhs.0.valueSats != rhs.0.valueSats
                ? lhs.0.valueSats < rhs.0.valueSats
                : lhs.1.lexicographicallyPrecedes(rhs.1)
        }.map(\.0)

        // 1. The smallest coin that pays for everything by itself.
        for utxo in ascending {
            if let selection = settle([utxo], targetSats: targetSats, satPerByte: satPerByte) { return selection }
        }
        // 2. No single coin is enough: add them smallest-first.
        var selected: [ThunderPointedOutput] = []
        for utxo in ascending {
            selected.append(utxo)
            if let selection = settle(selected, targetSats: targetSats, satPerByte: satPerByte) { return selection }
        }

        throw ThunderError.insufficientFunds(neededSats: Int64(clamping: targetSats),
                                             availableSats: Int64(clamping: available))
    }

    /// `selected` as a finished selection, or nil if it can't cover the payment plus fee. Priced as
    /// payment + change; if the change isn't worth its own output it's folded into the fee.
    private static func settle(_ selected: [ThunderPointedOutput],
                               targetSats: UInt64,
                               satPerByte: UInt64) -> ThunderCoinSelection? {
        let total = selected.reduce(UInt64(0)) { $0 &+ $1.valueSats }
        let feeWithChange = fee(inputCount: selected.count, outputCount: 2, satPerByte: satPerByte)
        guard total >= targetSats, total - targetSats >= feeWithChange else { return nil }

        let change = total - targetSats - feeWithChange
        let feeWithoutChange = fee(inputCount: selected.count, outputCount: 1, satPerByte: satPerByte)
        if change <= feeWithChange - feeWithoutChange {
            // Cheaper to hand the dust to the fee than to create the output.
            return ThunderCoinSelection(inputs: selected, changeSats: 0, feeSats: total - targetSats)
        }
        return ThunderCoinSelection(inputs: selected, changeSats: change, feeSats: feeWithChange)
    }

    /// Drain every spendable UTXO to a single output — the true "Max"/sweep. The amount sent is
    /// whatever is left after the fee, so there is no change output.
    static func selectAll(utxos: [ThunderPointedOutput],
                          satPerByte: UInt64) throws -> ThunderCoinSelection {
        guard !utxos.isEmpty else {
            throw ThunderError.insufficientFunds(neededSats: 0, availableSats: 0)
        }
        let total = utxos.reduce(UInt64(0)) { $0 &+ $1.valueSats }
        let feeSats = fee(inputCount: utxos.count, outputCount: 1, satPerByte: satPerByte)
        guard total > feeSats else {
            throw ThunderError.insufficientFunds(neededSats: Int64(clamping: feeSats),
                                                 availableSats: Int64(clamping: total))
        }
        return ThunderCoinSelection(inputs: utxos, changeSats: 0, feeSats: feeSats)
    }
}
