// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import Blake3
@testable import ECashWalletMobile

/// `PointedOutput` — the value whose hash identifies a UTXO in the utreexo accumulator, and which the
/// node re-derives when it regenerates a submitted transaction's proof. Expected bytes are assembled
/// here from the Borsh layout by hand (not by calling our encoder), so this is an independent check of
/// the wire format in thunder-rust `types/transaction.rs`.
@Suite struct ThunderPointedOutputTests {

    private static let address = [UInt8](repeating: 0xAB, count: 20)
    private static let txid = [UInt8](repeating: 0x11, count: 32)

    @Test func borshIsOutpointThenOutput() {
        let pointed = ThunderPointedOutput(
            outPoint: .regular(txid: Self.txid, vout: 7),
            output: ThunderOutput(address: Self.address, content: .value(sats: 5_000)))

        var expected: [UInt8] = []
        expected += [0]                                  // OutPoint tag 0 = Regular
        expected += Self.txid                            // [u8; 32], raw
        expected += [7, 0, 0, 0]                         // vout u32 LE
        expected += Self.address                         // Address = [u8; 20], raw
        expected += [0]                                  // Content tag 0 = Value
        expected += [136, 19, 0, 0, 0, 0, 0, 0]          // 5000 as u64 LE

        #expect(pointed.borshEncoded() == expected)
        #expect(pointed.borshEncoded().count == 37 + 29)   // outpoint 37 + output 29
    }

    @Test func utxoHashIsBlake3OfTheBorshBytes() {
        let pointed = ThunderPointedOutput(
            outPoint: .regular(txid: Self.txid, vout: 0),
            output: ThunderOutput(address: Self.address, content: .value(sats: 1)))
        // thunder-rust: `hash(&PointedOutput { .. })` = BLAKE3 over the borsh encoding.
        #expect(pointed.utxoHash() == Array(Blake3.hash(data: pointed.borshEncoded())))
        #expect(pointed.utxoHash().count == 32)
    }

    @Test func hashDistinguishesEveryField() {
        // Whatever differs — outpoint, vout, address or amount — must produce a different leaf, or a
        // proof would be regenerated against the wrong UTXO.
        let base = ThunderPointedOutput(outPoint: .regular(txid: Self.txid, vout: 0),
                                        output: ThunderOutput(address: Self.address, content: .value(sats: 1)))
        let otherVout = ThunderPointedOutput(outPoint: .regular(txid: Self.txid, vout: 1),
                                             output: base.output)
        let otherAmount = ThunderPointedOutput(outPoint: base.outPoint,
                                               output: ThunderOutput(address: Self.address, content: .value(sats: 2)))
        let otherAddress = ThunderPointedOutput(
            outPoint: base.outPoint,
            output: ThunderOutput(address: [UInt8](repeating: 0xCD, count: 20), content: .value(sats: 1)))
        let otherKind = ThunderPointedOutput(outPoint: .coinbase(merkleRoot: Self.txid, vout: 0),
                                             output: base.output)

        let hashes = Set([base, otherVout, otherAmount, otherAddress, otherKind].map { $0.utxoHash() })
        #expect(hashes.count == 5)
    }

    @Test func asInputCarriesTheComputedHash() {
        let pointed = ThunderPointedOutput(
            outPoint: .regular(txid: Self.txid, vout: 3),
            output: ThunderOutput(address: Self.address, content: .value(sats: 42)))
        let input = pointed.asInput()
        #expect(input.outPoint == pointed.outPoint)
        #expect(input.utxoHash == pointed.utxoHash())
    }

    @Test func withdrawalValueIncludesTheMainchainFee() {
        // Both the payout and the mainchain fee leave the sidechain (thunder-rust `GetValue`).
        let content = ThunderOutputContent.withdrawal(sats: 1_000, mainFeeSats: 300, mainScriptPubKey: [0x00])
        #expect(content.valueSats == 1_300)
        #expect(ThunderOutputContent.value(sats: 1_000).valueSats == 1_000)
    }

    @Test func borshSizeMatchesTheRealEncoding() {
        // The fee estimator prices a transaction before it exists — that size must be exact.
        let inputs = (0..<3).map { i in
            ThunderPointedOutput(outPoint: .regular(txid: Self.txid, vout: UInt32(i)),
                                 output: ThunderOutput(address: Self.address, content: .value(sats: 10))).asInput()
        }
        let outputs = [ThunderOutput(address: Self.address, content: .value(sats: 5)),
                       ThunderOutput(address: Self.address, content: .value(sats: 4))]
        let tx = ThunderTransaction(inputs: inputs, outputs: outputs)
        #expect(ThunderTransaction.borshSize(inputCount: 3, outputs: outputs.map(\.content))
                == tx.borshEncoded().count)
    }
}
