// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// Known-answer vectors from thunder-rust **v0.18.1's own `thunder_types` crate** (b62658f): a scratch
/// program builds this fixture with the real types and prints `borsh::to_vec` / `hash` / `txid`
/// (docs/thunder-key-port.md step 2). Thunder's types were heavily restructured between the branch our
/// older Borsh vectors came from and 0.18, so these pin the CURRENT wire format.
///
/// The same program also ran thunder-rust's `verify_authorized_transaction` on the authorizations this
/// suite's `signedFixture()` produces (see the log line it prints) — VERIFY=OK, and each signing key's
/// `get_address` equals the spent output's address.
@Suite struct ThunderTransaction018Tests {
    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    private func toHex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private func address(_ b58: String) -> [UInt8] { ThunderAddress(base58: b58)!.bytes }

    private var depositUTXO: ThunderPointedOutput {
        ThunderPointedOutput(outPoint: .deposit(txid: [UInt8](repeating: 0x11, count: 32), vout: 1),
                             output: ThunderOutput(address: address("NKqSr4bQejFbKpd5yLQgWEiMJFx"),
                                                   content: .value(sats: 100_000)))
    }
    private var regularUTXO: ThunderPointedOutput {
        ThunderPointedOutput(outPoint: .regular(txid: [UInt8](repeating: 0x22, count: 32), vout: 3),
                             output: ThunderOutput(address: address("2n9MH4oiBFs4sRby3cC8VBaE71Zw"),
                                                   content: .value(sats: 25_000)))
    }
    private var transaction: ThunderTransaction {
        ThunderTransaction(
            inputs: [depositUTXO.asInput(), regularUTXO.asInput()],
            outputs: [
                ThunderOutput(address: address("3Ye7y38EwGcSXVbZgxsR8kMAnhPs"), content: .value(sats: 80_000)),
                // bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4 (BIP173) → P2WPKH scriptPubKey
                ThunderOutput(address: address("NKqSr4bQejFbKpd5yLQgWEiMJFx"),
                              content: .withdrawal(sats: 40_000, mainFeeSats: 1_000,
                                                   mainAddress: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
                                                   mainScriptPubKey: hex("0014751e76e8199196d454941c45d1b3a323f1433bd6"))),
            ])
    }

    @Test func pointedOutputsMatchThunder018() {
        #expect(toHex(depositUTXO.borshEncoded()) == "021111111111111111111111111111111111111111111111111111111111111111010000001a640aafdf45444c2fc37b424ab4cb5f82ee525700a086010000000000")
        #expect(toHex(depositUTXO.utxoHash()) == "c3a5b2bd3603dff8a1c15b4e2cbd54e288cd64a2395d6f04ee8f08f3163db70c")
        #expect(toHex(regularUTXO.borshEncoded()) == "002222222222222222222222222222222222222222222222222222222222222222030000007fa5c20e9fc8401ba4b6a6e80cf862390fd2dd5600a861000000000000")
        #expect(toHex(regularUTXO.utxoHash()) == "b68ede6d0df75c210e0cf3a3aa87565eb11ff4fd385575d787e9d9a6894e0b49")
    }

    @Test func transactionBytesAndTxidMatchThunder018() {
        #expect(toHex(transaction.borshEncoded()) == "0200000002111111111111111111111111111111111111111111111111111111111111111101000000c3a5b2bd3603dff8a1c15b4e2cbd54e288cd64a2395d6f04ee8f08f3163db70c00222222222222222222222222222222222222222222222222222222222222222203000000b68ede6d0df75c210e0cf3a3aa87565eb11ff4fd385575d787e9d9a6894e0b4902000000b6b6dc3b72a299fc106bcb55aa4b14eb3337e8260080380100000000001a640aafdf45444c2fc37b424ab4cb5f82ee525701409c000000000000e803000000000000160000000014751e76e8199196d454941c45d1b3a323f1433bd6")
        #expect(toHex(transaction.txid()) == "86d5086fc4d5ab62d5d0ee4ec48240086cf1e2f06edffb68e1a61989fc982b35")
    }

    /// Signs the fixture with the 0.18 keys for its two inputs (indices 0 and 1 of "abandon ×11 about")
    /// and prints `vk sig` pairs for the Rust `verify` cross-check. Also verifies locally.
    @Test func signedFixture() throws {
        let scheme = RistrettoSidechainKeyScheme.thunder
        let seed = Bip39Seed.seed(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let message = transaction.borshEncoded()
        var line: [String] = []
        for index in [UInt32(0), 1] {
            let secret = try scheme.signingKey(seed: seed, index: index)
            let publicKey = try Ristretto255Point.base(secret)
            let signature = try FrostSchnorr.sign(message: message, secret: secret)
            #expect(FrostSchnorr.verify(signature: signature, publicKey: publicKey, message: message))
            line += [toHex(publicKey), toHex(signature)]
        }
        print("THUNDER018_AUTH \(line.joined(separator: " "))")
    }

    /// A signed fixture with FIXED authorizations (captured from a `signedFixture()` run that
    /// thunder-rust verified), so the full authorized encodings can be pinned byte-for-byte.
    private var authorized: AuthorizedThunderTransaction {
        AuthorizedThunderTransaction(transaction: transaction, authorizations: [
            ThunderAuthorization(verifyingKey: hex("340716be9eea730162132404747f15cde3809e0513ceef5131be81971ec5a131"),
                                 signature: hex("20267b9c2c6abbbd7eb453666c101fd6dcf50f5ec5ad8da0516dc9b368b77569a97442d45ef976438847f3c7471cfa0e64d23c47227b016c92f34eed14712300")),
            ThunderAuthorization(verifyingKey: hex("fe1d62d493cc77443db58985b69d000a3ca63be8ca5a9831253e7a79ed29ff10"),
                                 signature: hex("0c21b56e812cd93a062b2b917d9ba51f2ca895bc41f8afc1f9bac16e3b59fe1fa2c43d261e147e81749a2685f696c30502315d4b0fc7f228ad33b68048d0bb0d")),
        ])
    }

    @Test func authorizedBorshMatchesThunder018() {
        #expect(toHex(authorized.borshEncoded()) == "0200000002111111111111111111111111111111111111111111111111111111111111111101000000c3a5b2bd3603dff8a1c15b4e2cbd54e288cd64a2395d6f04ee8f08f3163db70c00222222222222222222222222222222222222222222222222222222222222222203000000b68ede6d0df75c210e0cf3a3aa87565eb11ff4fd385575d787e9d9a6894e0b4902000000b6b6dc3b72a299fc106bcb55aa4b14eb3337e8260080380100000000001a640aafdf45444c2fc37b424ab4cb5f82ee525701409c000000000000e803000000000000160000000014751e76e8199196d454941c45d1b3a323f1433bd602000000340716be9eea730162132404747f15cde3809e0513ceef5131be81971ec5a13120267b9c2c6abbbd7eb453666c101fd6dcf50f5ec5ad8da0516dc9b368b77569a97442d45ef976438847f3c7471cfa0e64d23c47227b016c92f34eed14712300fe1d62d493cc77443db58985b69d000a3ca63be8ca5a9831253e7a79ed29ff100c21b56e812cd93a062b2b917d9ba51f2ca895bc41f8afc1f9bac16e3b59fe1fa2c43d261e147e81749a2685f696c30502315d4b0fc7f228ad33b68048d0bb0d")
    }

    /// The JSON both backends submit (`submit_transaction` / index `POST /tx`), against v0.18.1's own
    /// `serde_json::to_string`. Compared as parsed JSON, so key order doesn't matter but every value does
    /// — notably `verifying_key`/`signature` as HEX STRINGS (0.18) and `main_address` as an address string.
    @Test func submitJSONMatchesThunder018() throws {
        let ours = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ThunderRPCAuthorizedTransaction(authorized: authorized))) as? NSDictionary
        let theirs = try JSONSerialization.jsonObject(with: Data(Self.rustJSON.utf8)) as? NSDictionary
        #expect(ours != nil && ours == theirs)

    }

    /// 0.18 names the withdrawal fields `value` / `main_fee`; older nodes wrote `value_sats` /
    /// `main_fee_sats`. Both decode to the same content.
    @Test func withdrawalContentDecodesBothFieldSpellings() throws {
        let current = #"{"Withdrawal":{"value":40000,"main_fee":1000,"main_address":"bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"}}"#
        let legacy = #"{"Withdrawal":{"value_sats":40000,"main_fee_sats":1000,"main_address":"bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"}}"#
        let expected = ThunderRPCContent.withdrawal(valueSats: 40_000, mainFeeSats: 1_000,
                                                    mainAddress: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        #expect(try JSONDecoder().decode(ThunderRPCContent.self, from: Data(current.utf8)) == expected)
        #expect(try JSONDecoder().decode(ThunderRPCContent.self, from: Data(legacy.utf8)) == expected)
    }

    private static let rustJSON = #"{"transaction":{"inputs":[[{"Deposit":"1111111111111111111111111111111111111111111111111111111111111111:1"},[195,165,178,189,54,3,223,248,161,193,91,78,44,189,84,226,136,205,100,162,57,93,111,4,238,143,8,243,22,61,183,12]],[{"Regular":{"txid":"2222222222222222222222222222222222222222222222222222222222222222","vout":3}},[182,142,222,109,13,247,92,33,14,12,243,163,170,135,86,94,177,31,244,253,56,85,117,215,135,233,217,166,137,78,11,73]]],"proof":{"targets":[],"hashes":[]},"outputs":[{"address":"3Ye7y38EwGcSXVbZgxsR8kMAnhPs","content":{"Value":80000}},{"address":"NKqSr4bQejFbKpd5yLQgWEiMJFx","content":{"Withdrawal":{"value":40000,"main_fee":1000,"main_address":"bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"}}}]},"authorizations":[{"verifying_key":"340716be9eea730162132404747f15cde3809e0513ceef5131be81971ec5a131","signature":"20267b9c2c6abbbd7eb453666c101fd6dcf50f5ec5ad8da0516dc9b368b77569a97442d45ef976438847f3c7471cfa0e64d23c47227b016c92f34eed14712300"},{"verifying_key":"fe1d62d493cc77443db58985b69d000a3ca63be8ca5a9831253e7a79ed29ff10","signature":"0c21b56e812cd93a062b2b917d9ba51f2ca895bc41f8afc1f9bac16e3b59fe1fa2c43d261e147e81749a2685f696c30502315d4b0fc7f228ad33b68048d0bb0d"}]}"#
}
