// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Blake3

/// A UTXO — an outpoint together with the output it points at (thunder-rust `types::PointedOutput`).
/// This is what `get_utxos` returns, and it is also the value whose hash identifies a UTXO inside the
/// utreexo accumulator.
///
/// **Why this type earns its keep:** every transaction input is `(OutPoint, Hash)`, where the `Hash` is
/// `BLAKE3(borsh(PointedOutput))` of the UTXO being spent (thunder-rust `wallet.rs`, which builds
/// inputs as `hash(&PointedOutput { outpoint, output })`). The node uses exactly those hashes as the
/// utreexo *targets* it proves against when `submit_transaction` regenerates the proof
/// (`State::regenerate_proof`). So the client MUST compute this hash byte-identically: get it wrong and
/// the node proves the wrong leaf and rejects the transaction. Consensus-critical — keep it exact.
struct ThunderPointedOutput: Equatable {
    let outPoint: ThunderOutPoint
    let output: ThunderOutput

    /// Canonical Borsh encoding — byte-identical to thunder-rust's `borsh::to_vec(&pointed_output)`:
    /// the outpoint followed by the output, no wrapper, no length prefix.
    func borshEncoded() -> [UInt8] {
        var w = BorshWriter()
        outPoint.borshEncode(into: &w)
        output.borshEncode(into: &w)
        return w.bytes
    }

    /// The 32-byte UTXO hash used as this UTXO's utreexo leaf and as the second element of the input
    /// tuple: `BLAKE3(borsh(PointedOutput))` (thunder-rust `hashes::hash`).
    func utxoHash() -> [UInt8] {
        Array(Blake3.hash(data: borshEncoded()))
    }

    /// This UTXO as a transaction input, with its hash already computed.
    func asInput() -> ThunderTransaction.Input {
        ThunderTransaction.Input(outPoint: outPoint, utxoHash: utxoHash())
    }

    /// The value this UTXO carries, in sats.
    var valueSats: UInt64 { output.content.valueSats }

    /// The address controlling this UTXO — the key we must resolve to sign an input spending it.
    var address: ThunderAddress { ThunderAddress(bytes: output.address) }
}
