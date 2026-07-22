// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import Crypto
@testable import ECashWalletMobile

/// `ThunderWallet` — deriving the address set and resolving address→key to sign node-built
/// transactions. The signing pipeline the engine will call: node returns an unsigned tx + the address
/// each input spends; the wallet finds the controlling key per input and authorizes.
@Suite struct ThunderWalletTests {

    private static let mnemonic = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"
    private static let wallet = ThunderWallet(mnemonic: mnemonic)

    private static func input(_ fill: UInt8) -> ThunderTransaction.Input {
        .init(outPoint: .regular(txid: [UInt8](repeating: fill, count: 32), vout: 0),
              utxoHash: [UInt8](repeating: fill, count: 32))
    }

    // MARK: - Derivation

    @Test func addressesMatchDirectKeyDerivation() throws {
        for index in UInt32(0)..<5 {
            #expect(try Self.wallet.address(at: index)
                    == (try ThunderKey.derive(mnemonic: Self.mnemonic, index: index)).address)
        }
    }

    @Test func addressesAreDistinctAndDeterministic() throws {
        let a = try Self.wallet.addresses(count: 10)
        let b = try Self.wallet.addresses(count: 10)
        #expect(a == b)                          // deterministic
        #expect(Set(a.map(\.base58)).count == 10)  // all distinct
    }

    @Test func firstAddressIsTheGolden() throws {
        // ties ThunderWallet to the pinned key-layer golden
        #expect(try Self.wallet.address(at: 0).base58 == "38VvRdmcQREr1UAcZma98WLFVpAp")
    }

    // MARK: - address → key resolution

    @Test func resolvesKeyForOwnedAddress() throws {
        let target = try Self.wallet.address(at: 7)
        let resolved = try Self.wallet.key(for: target, searchLimit: 20)
        #expect(resolved?.address == target)
        #expect(resolved?.index == 7)
    }

    @Test func returnsNilForUnownedAddress() throws {
        let foreign = ThunderAddress(bytes: [UInt8](repeating: 0xEE, count: 20))
        #expect(try Self.wallet.key(for: foreign, searchLimit: 20) == nil)
    }

    @Test func respectsSearchLimit() throws {
        let deep = try Self.wallet.address(at: 30)
        #expect(try Self.wallet.key(for: deep, searchLimit: 10) == nil)   // beyond the limit
        #expect(try Self.wallet.key(for: deep, searchLimit: 40)?.index == 30)
    }

    // MARK: - authorize by input address

    @Test func authorizeResolvesKeysAndSignsEachInput() throws {
        let addr0 = try Self.wallet.address(at: 3)
        let addr1 = try Self.wallet.address(at: 8)
        let tx = ThunderTransaction(
            inputs: [Self.input(0x01), Self.input(0x02)],
            outputs: [ThunderOutput(address: addr0.bytes, content: .value(sats: 2500))])

        let atx = try Self.wallet.authorize(tx, inputAddresses: [addr0, addr1], searchLimit: 20)

        #expect(atx.authorizations.count == 2)
        let message = Data(tx.borshEncoded())
        for (auth, addr) in zip(atx.authorizations, [addr0, addr1]) {
            #expect(ThunderAddress(publicKey: auth.verifyingKey) == addr)   // right key for the input
            let vk = try Curve25519.Signing.PublicKey(rawRepresentation: auth.verifyingKey)
            #expect(vk.isValidSignature(Data(auth.signature), for: message))
        }
    }

    @Test func authorizeThrowsWhenInputAddressNotOwned() throws {
        let owned = try Self.wallet.address(at: 0)
        let foreign = ThunderAddress(bytes: [UInt8](repeating: 0xEE, count: 20))
        let tx = ThunderTransaction(inputs: [Self.input(0x01), Self.input(0x02)], outputs: [])
        do {
            _ = try Self.wallet.authorize(tx, inputAddresses: [owned, foreign], searchLimit: 20)
            Issue.record("expected authorize to throw for an unowned input address")
        } catch let error as ThunderError {
            #expect(error == .noKeyForInputAddress(inputIndex: 1))
        }
    }

    @Test func authorizeThrowsOnAddressCountMismatch() throws {
        let owned = try Self.wallet.address(at: 0)
        let tx = ThunderTransaction(inputs: [Self.input(0x01), Self.input(0x02)], outputs: [])
        do {
            _ = try Self.wallet.authorize(tx, inputAddresses: [owned], searchLimit: 20)   // 2 inputs, 1 addr
            Issue.record("expected authorize to throw on input/address count mismatch")
        } catch let error as ThunderError {
            #expect(error == .inputAddressCountMismatch(inputs: 2, addresses: 1))
        }
    }
}
