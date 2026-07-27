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

    /// Select coins to pay `targetSats` plus fee. Largest-first: it reaches the target in the fewest
    /// inputs, which keeps both the fee and the number of signatures down.
    ///
    /// If the leftover change is worth less than the output it would occupy, it is dropped into the fee
    /// instead of creating a UTXO that costs more to spend than it holds.
    static func select(utxos: [ThunderPointedOutput],
                       targetSats: UInt64,
                       satPerByte: UInt64) throws -> ThunderCoinSelection {
        let available = utxos.reduce(UInt64(0)) { $0 &+ $1.valueSats }
        var selected: [ThunderPointedOutput] = []
        var total: UInt64 = 0

        for utxo in utxos.sorted(by: { $0.valueSats > $1.valueSats }) {
            selected.append(utxo)
            total &+= utxo.valueSats

            // Price the tx as payment + change; if the change turns out not to be worth keeping we
            // re-price it as a single-output tx below.
            let feeWithChange = fee(inputCount: selected.count, outputCount: 2, satPerByte: satPerByte)
            guard total >= targetSats, total - targetSats >= feeWithChange else { continue }

            let change = total - targetSats - feeWithChange
            let feeWithoutChange = fee(inputCount: selected.count, outputCount: 1, satPerByte: satPerByte)
            let changeOutputCost = feeWithChange - feeWithoutChange
            if change <= changeOutputCost {
                // Cheaper to hand the dust to the fee than to create the output.
                return ThunderCoinSelection(inputs: selected, changeSats: 0, feeSats: total - targetSats)
            }
            return ThunderCoinSelection(inputs: selected, changeSats: change, feeSats: feeWithChange)
        }

        throw ThunderError.insufficientFunds(neededSats: Int64(clamping: targetSats),
                                             availableSats: Int64(clamping: available))
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
