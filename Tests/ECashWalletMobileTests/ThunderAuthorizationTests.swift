// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import Crypto
@testable import ECashWalletMobile

/// Client-side authorization: turning an unsigned `ThunderTransaction` into the submit-ready
/// `AuthorizedThunderTransaction`. The security-critical invariants: one authorization per input in
/// input order, each a real ed25519 signature over `borsh(transaction)` by the key controlling that
/// input, and `BLAKE3(vk)[..20]` matching the key's address (the input↔key binding Thunder enforces).
@Suite struct ThunderAuthorizationTests {

    private static let mnemonic = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    private static func input(_ fill: UInt8, vout: UInt32) -> ThunderTransaction.Input {
        .init(outPoint: .regular(txid: [UInt8](repeating: fill, count: 32), vout: vout),
              utxoHash: [UInt8](repeating: fill, count: 32))
    }

    // MARK: - Borsh layout

    @Test func authorizationBorshIsKeyThenSignature96Bytes() {
        let auth = ThunderAuthorization(verifyingKey: [UInt8](repeating: 0xAA, count: 32),
                                        signature: [UInt8](repeating: 0xBB, count: 64))
        let atx = AuthorizedThunderTransaction(
            transaction: ThunderTransaction(inputs: [], outputs: []), authorizations: [auth])
        var expected: [UInt8] = []
        expected += [0, 0, 0, 0,  0, 0, 0, 0]              // borsh(empty transaction): two zero counts
        expected += [1, 0, 0, 0]                            // Vec<Authorization> len 1
        expected += [UInt8](repeating: 0xAA, count: 32)     // verifying_key [u8; 32]
        expected += [UInt8](repeating: 0xBB, count: 64)     // signature [u8; 64]
        #expect(atx.borshEncoded() == expected)
        #expect(atx.borshEncoded().count == 8 + 4 + 96)
    }

    @Test func authorizedBorshStartsWithBareTransactionBytes() {
        // The Authorized<T> encoding must begin with exactly borsh(transaction) — the message that was
        // signed — so that the wrapper doesn't disturb the signed prefix.
        let tx = ThunderTransaction(inputs: [], outputs: [
            ThunderOutput(address: [UInt8](repeating: 5, count: 20), content: .value(sats: 7))
        ])
        let atx = AuthorizedThunderTransaction(transaction: tx, authorizations: [])
        let encoded = atx.borshEncoded()
        #expect(Array(encoded.prefix(tx.borshEncoded().count)) == tx.borshEncoded())
        #expect(Array(encoded.suffix(4)) == [0, 0, 0, 0])   // empty Vec<Authorization>
    }

    // MARK: - authorize()

    @Test func authorizeProducesOneVerifiableAuthorizationPerInputInOrder() throws {
        let key0 = try ThunderKey.derive(mnemonic: Self.mnemonic, index: 0)
        let key1 = try ThunderKey.derive(mnemonic: Self.mnemonic, index: 1)
        let tx = ThunderTransaction(
            inputs: [Self.input(0x01, vout: 0), Self.input(0x02, vout: 1)],   // input[0]→key0, input[1]→key1
            outputs: [ThunderOutput(address: key0.address.bytes, content: .value(sats: 1000))])

        let atx = try AuthorizedThunderTransaction.authorize(tx, inputKeys: [key0, key1])

        #expect(atx.authorizations.count == 2)
        let message = Data(tx.borshEncoded())
        for (auth, key) in zip(atx.authorizations, [key0, key1]) {
            #expect(auth.verifyingKey == key.publicKeyBytes)
            // BLAKE3(vk)[..20] == the key's address — the input↔key binding Thunder checks.
            #expect(ThunderAddress(publicKey: auth.verifyingKey) == key.address)
            let vk = try Curve25519.Signing.PublicKey(rawRepresentation: auth.verifyingKey)
            #expect(vk.isValidSignature(Data(auth.signature), for: message))   // signs borsh(transaction)
        }
    }

    @Test func authorizeRejectsKeyInputCountMismatch() throws {
        let key0 = try ThunderKey.derive(mnemonic: Self.mnemonic, index: 0)
        let tx = ThunderTransaction(inputs: [Self.input(0x01, vout: 0)], outputs: [])   // 1 input
        do {
            _ = try AuthorizedThunderTransaction.authorize(tx, inputKeys: [])            // 0 keys
            Issue.record("expected authorize to throw on input/key count mismatch")
        } catch let error as ThunderError {
            #expect(error == .authorizationKeyCountMismatch(inputs: 1, keys: 0))
        }
    }

    @Test func authorizeEmptyTransactionHasNoAuthorizations() throws {
        let tx = ThunderTransaction(inputs: [], outputs: [])
        let atx = try AuthorizedThunderTransaction.authorize(tx, inputKeys: [])
        #expect(atx.authorizations.isEmpty)
        #expect(atx.borshEncoded() == [0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0])   // tx(8) + empty auth vec(4)
    }
}
