// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Blake3   // txid = BLAKE3(borsh(transaction))

/// A reference to the UTXO an input spends (thunder-rust `types::OutPoint`). Each variant's Borsh
/// encoding is `u8 tag || [u8; 32] hash || u32 vout` (37 bytes) — the tag distinguishes how the UTXO
/// was created. `deposit` wraps a *mainchain* bitcoin outpoint (raw internal txid bytes + vout).
enum ThunderOutPoint: Equatable {
    case regular(txid: [UInt8], vout: UInt32)          // tag 0 — created by a Thunder tx
    case coinbase(merkleRoot: [UInt8], vout: UInt32)   // tag 1 — created by a block body
    case deposit(txid: [UInt8], vout: UInt32)          // tag 2 — created by a mainchain deposit
}

/// An output's payload (thunder-rust `types::Content`). `bitcoin::Amount` serializes as its u64 sats.
enum ThunderOutputContent: Equatable {
    case value(sats: UInt64)                            // tag 0 — a plain payment
    /// A withdrawal to the mainchain (BIP300/301). `mainScriptPubKey` is the destination mainchain
    /// address's scriptPubKey bytes (what thunder-rust serializes for `main_address`). Future work —
    /// the everyday send path only uses `.value`.
    case withdrawal(sats: UInt64, mainFeeSats: UInt64, mainScriptPubKey: [UInt8])   // tag 1
}

/// A transaction output (thunder-rust `types::Output`): a 20-byte address hash plus its content.
struct ThunderOutput: Equatable {
    let address: [UInt8]           // 20-byte Thunder address hash (`ThunderAddress.bytes`)
    let content: ThunderOutputContent
}

/// A Thunder transaction — the exact value that is BLAKE3-hashed for its txid and ed25519-signed for
/// authorization. Mirrors thunder-rust `types::Transaction` MINUS the utreexo `proof`, which is
/// `#[borsh(skip)]`, so it never enters the signed bytes. That skip is what lets the client sign
/// without the accumulator: the phone builds inputs + outputs and signs; the node fills the proof in
/// `submit_transaction` (decided 2026-07-23; docs/thunder-sidechain-support.md §8b). Each input pairs
/// an `OutPoint` with the spent UTXO's 32-byte hash.
struct ThunderTransaction: Equatable {
    struct Input: Equatable {
        let outPoint: ThunderOutPoint
        let utxoHash: [UInt8]      // `Hash` = [u8; 32], the hash of the spent PointedOutput
    }

    let inputs: [Input]
    let outputs: [ThunderOutput]

    /// Canonical Borsh encoding — byte-identical to thunder-rust's `borsh::to_vec(&transaction)`.
    /// This is the message `ThunderKey.sign` signs, and what BLAKE3 hashes to the txid.
    func borshEncoded() -> [UInt8] {
        var w = BorshWriter()
        // inputs: Vec<(OutPoint, Hash)>  — u32 count, then each (outpoint, 32-byte hash)
        w.writeU32(UInt32(inputs.count))
        for input in inputs {
            Self.encodeOutPoint(input.outPoint, into: &w)
            w.writeFixedBytes(input.utxoHash)
        }
        // proof: #[borsh(skip)] — deliberately omitted
        // outputs: Vec<Output>  — u32 count, then each (20-byte address, content)
        w.writeU32(UInt32(outputs.count))
        for output in outputs {
            w.writeFixedBytes(output.address)
            Self.encodeContent(output.content, into: &w)
        }
        return w.bytes
    }

    /// The transaction id: `BLAKE3(borsh(transaction))` (thunder-rust `Transaction::txid`).
    func txid() -> [UInt8] {
        Array(Blake3.hash(data: borshEncoded()))
    }

    private static func encodeOutPoint(_ op: ThunderOutPoint, into w: inout BorshWriter) {
        switch op {
        case let .regular(txid, vout):
            w.writeU8(0); w.writeFixedBytes(txid); w.writeU32(vout)
        case let .coinbase(merkleRoot, vout):
            w.writeU8(1); w.writeFixedBytes(merkleRoot); w.writeU32(vout)
        case let .deposit(txid, vout):
            w.writeU8(2); w.writeFixedBytes(txid); w.writeU32(vout)
        }
    }

    private static func encodeContent(_ c: ThunderOutputContent, into w: inout BorshWriter) {
        switch c {
        case let .value(sats):
            w.writeU8(0); w.writeU64(sats)
        case let .withdrawal(sats, mainFeeSats, mainScriptPubKey):
            w.writeU8(1); w.writeU64(sats); w.writeU64(mainFeeSats); w.writeVarBytes(mainScriptPubKey)
        }
    }
}
