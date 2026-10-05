// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// `ManagedWallet.derivationPath` — the path shown on Receive and in tx detail — is read from the
/// descriptor's key origin, so it must reproduce the script type, coin type and account exactly.
final class DerivationPathTests: XCTestCase {

    private func wallet(_ external: String, _ internalDesc: String,
                        keyType: WalletKeyType = WalletKeyType.mnemonic) -> ManagedWallet {
        ManagedWallet(id: "w", label: "t", network: WalletNetwork.signet,
                      externalDescriptor: external, internalDescriptor: internalDesc, keyType: keyType)
    }

    func testReceiveAndChangePathsFromKeyOrigin() {
        let w = wallet("wpkh([d34db33f/84'/1'/0']tpubXYZ/0/*)#abcd1234",
                       "wpkh([d34db33f/84'/1'/0']tpubXYZ/1/*)#efgh5678")
        XCTAssertEqual(w.derivationPath(isChange: false, index: Int32(5)), "m/84'/1'/0'/0/5")
        XCTAssertEqual(w.derivationPath(isChange: true, index: Int32(12)), "m/84'/1'/0'/1/12")
    }

    func testHardenedHMarkerIsNormalised() {
        let w = wallet("tr([d34db33f/86h/0h/3h]xpubXYZ/0/*)", "tr([d34db33f/86h/0h/3h]xpubXYZ/1/*)")
        XCTAssertEqual(w.derivationPath(isChange: false, index: Int32(0)), "m/86'/0'/3'/0/0")
    }

    func testNestedSegwitOriginInsideWrapper() {
        let w = wallet("sh(wpkh([d34db33f/49'/0'/0']xpubXYZ/0/*))", "sh(wpkh([d34db33f/49'/0'/0']xpubXYZ/1/*))")
        XCTAssertEqual(w.derivationPath(isChange: false, index: Int32(7)), "m/49'/0'/0'/0/7")
    }

    func testNoPathForWifOrOriginlessDescriptor() {
        let wif = wallet("pkh(0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798)",
                         "pkh(0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798)",
                         keyType: WalletKeyType.wif)
        XCTAssertNil(wif.derivationPath(isChange: false, index: Int32(0)))
        XCTAssertNil(wallet("wpkh(tpubXYZ/0/*)", "wpkh(tpubXYZ/1/*)").derivationPath(isChange: false, index: Int32(0)))
    }

    func testWithTimestampKeepsOwnKeys() {
        let keys = [TxKeyUse(isInput: true, isChange: false, index: Int32(3)),
                    TxKeyUse(isInput: false, isChange: true, index: Int32(1))]
        let tx = WalletTx(txid: "t", netSats: Int64(-10), feeSats: nil, confirmations: Int32(0),
                          timestampEpochSeconds: nil, isRBF: true, ownKeys: keys)
        XCTAssertEqual(tx.withTimestamp(Int64(100)).ownKeys, keys)
    }
}
