// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import Crypto
@testable import ECashWalletMobile

/// The Borsh codec for Thunder's signed `Transaction`. Each expected byte string is assembled here
/// from the Borsh layout (u32 LE counts, u8 enum tags, little-endian integers, raw fixed arrays) —
/// NOT by calling our own encoder — so the tests are an independent spec check, not a tautology. The
/// wire format is drawn from thunder-rust `types/transaction.rs` (+ `Hash`/`Txid` = `[u8; 32]`,
/// `Address` = `[u8; 20]`, `bitcoin::Amount` → u64 sats). TODO: cross-check one full vector against a
/// real thunder-rust `borsh::to_vec` before enabling sends (docs/thunder-sidechain-support.md).
@Suite struct ThunderBorshTests {

    // MARK: - Transaction envelope

    @Test func emptyTransactionIsTwoZeroCounts() {
        let tx = ThunderTransaction(inputs: [], outputs: [])
        #expect(tx.borshEncoded() == [0, 0, 0, 0,   // inputs: Vec len 0
                                      0, 0, 0, 0])   // outputs: Vec len 0
    }

    @Test func proofIsNotSerialized() {
        // A tx with outputs but no inputs must still be exactly: len(0) ++ len(1) ++ output.
        // (If the utreexo proof leaked in, the byte count would differ.)
        let tx = ThunderTransaction(inputs: [], outputs: [
            ThunderOutput(address: [UInt8](repeating: 0, count: 20), content: .value(sats: 0))
        ])
        // 4 (in count) + 4 (out count) + 20 (addr) + 1 (Value tag) + 8 (u64) = 37
        #expect(tx.borshEncoded().count == 37)
    }

    // MARK: - Content::Value

    @Test func singleValueOutput() {
        let addr = [UInt8](repeating: 0xAB, count: 20)
        let tx = ThunderTransaction(inputs: [], outputs: [
            ThunderOutput(address: addr, content: .value(sats: 1000))
        ])
        var expected: [UInt8] = []
        expected += [0, 0, 0, 0]                        // inputs count 0
        expected += [1, 0, 0, 0]                        // outputs count 1
        expected += addr                                // Address [u8; 20]
        expected += [0]                                 // Content::Value tag
        expected += [0xE8, 0x03, 0, 0, 0, 0, 0, 0]      // 1000 as u64 LE
        #expect(tx.borshEncoded() == expected)
    }

    // MARK: - OutPoint variants (inputs)

    @Test func regularInputWithValueOutput() {
        let txid = [UInt8](repeating: 0x01, count: 32)
        let utxoHash = [UInt8](repeating: 0x02, count: 32)
        let addr = [UInt8](repeating: 0x03, count: 20)
        let tx = ThunderTransaction(
            inputs: [.init(outPoint: .regular(txid: txid, vout: 2), utxoHash: utxoHash)],
            outputs: [ThunderOutput(address: addr, content: .value(sats: 500))])
        var expected: [UInt8] = []
        expected += [1, 0, 0, 0]                        // inputs count 1
        expected += [0]                                 // OutPoint::Regular tag
        expected += txid                                // Txid [u8; 32]
        expected += [2, 0, 0, 0]                        // vout u32 LE
        expected += utxoHash                            // Hash [u8; 32]
        expected += [1, 0, 0, 0]                        // outputs count 1
        expected += addr                                // Address [u8; 20]
        expected += [0]                                 // Content::Value tag
        expected += [0xF4, 0x01, 0, 0, 0, 0, 0, 0]      // 500 as u64 LE
        #expect(tx.borshEncoded() == expected)
    }

    @Test func outPointTagsAreZeroOneTwo() {
        let h32 = [UInt8](repeating: 0, count: 32)
        func firstByteOfOnlyInput(_ op: ThunderOutPoint) -> UInt8 {
            let tx = ThunderTransaction(inputs: [.init(outPoint: op, utxoHash: h32)], outputs: [])
            return tx.borshEncoded()[4]   // byte[0..4] is the inputs count; byte[4] is the tag
        }
        #expect(firstByteOfOnlyInput(.regular(txid: h32, vout: 0)) == 0)
        #expect(firstByteOfOnlyInput(.coinbase(merkleRoot: h32, vout: 0)) == 1)
        #expect(firstByteOfOnlyInput(.deposit(txid: h32, vout: 0)) == 2)
    }

    // MARK: - Content::Withdrawal

    @Test func withdrawalContentEncoding() {
        let addr = [UInt8](repeating: 0, count: 20)
        let spk: [UInt8] = [0xAA, 0xBB, 0xCC]           // stand-in mainchain scriptPubKey
        let tx = ThunderTransaction(inputs: [], outputs: [
            ThunderOutput(address: addr, content: .withdrawal(sats: 1000, mainFeeSats: 300, mainScriptPubKey: spk))
        ])
        var expected: [UInt8] = []
        expected += [0, 0, 0, 0]                        // inputs count 0
        expected += [1, 0, 0, 0]                        // outputs count 1
        expected += addr                                // Address [u8; 20]
        expected += [1]                                 // Content::Withdrawal tag
        expected += [0xE8, 0x03, 0, 0, 0, 0, 0, 0]      // value 1000 u64 LE
        expected += [0x2C, 0x01, 0, 0, 0, 0, 0, 0]      // main_fee 300 u64 LE
        expected += [3, 0, 0, 0]                        // scriptPubKey Vec<u8> len
        expected += spk
        #expect(tx.borshEncoded() == expected)
    }

    // MARK: - Wiring: txid + signing

    @Test func txidIsDeterministic32ByteHash() {
        // txid() = BLAKE3(borsh) — verified for correctness via ThunderAddress's golden test (same
        // BLAKE3 path). Here we just pin the wiring: 32 bytes, deterministic, sensitive to the bytes.
        let tx = ThunderTransaction(inputs: [], outputs: [
            ThunderOutput(address: [UInt8](repeating: 7, count: 20), content: .value(sats: 42))
        ])
        let other = ThunderTransaction(inputs: [], outputs: [
            ThunderOutput(address: [UInt8](repeating: 7, count: 20), content: .value(sats: 43))
        ])
        #expect(tx.txid().count == 32)
        #expect(tx.txid() == tx.txid())          // deterministic
        #expect(tx.txid() != other.txid())       // one sat difference changes the id
    }

    @Test func keySignsTransactionAndVerifies() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon about"
        let key = try ThunderKey.derive(mnemonic: mnemonic, index: 0)
        let tx = ThunderTransaction(
            inputs: [.init(outPoint: .regular(txid: [UInt8](repeating: 9, count: 32), vout: 0),
                           utxoHash: [UInt8](repeating: 8, count: 32))],
            outputs: [ThunderOutput(address: key.address.bytes, content: .value(sats: 21_000))])
        // Thunder authorizes an input by ed25519-signing borsh(transaction).
        let signature = try key.sign(tx.borshEncoded())
        #expect(signature.count == 64)
        let verifying = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKeyBytes)
        #expect(verifying.isValidSignature(Data(signature), for: Data(tx.borshEncoded())))
    }
}
