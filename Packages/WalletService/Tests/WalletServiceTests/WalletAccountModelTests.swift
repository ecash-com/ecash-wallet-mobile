// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// The seed-container model (`docs/seed-container-model.md §3`, step 2): `WalletAccount`, the
/// container `ManagedWallet`, its selected-account read-throughs, and the sidechain hierarchy.
final class WalletAccountModelTests: XCTestCase {

    private let ext = "wpkh([d34db33f/84'/0'/0']xpub6C/0/*)#aaaaaaaa"
    private let int = "wpkh([d34db33f/84'/0'/0']xpub6C/1/*)#bbbbbbbb"

    func testRetiredNetworksAreTheOnesOutsideThePickerAndTheirSidechains() {
        XCTAssertFalse(WalletNetwork.ecashMainnet.isRetired)
        XCTAssertFalse(WalletNetwork.bitcoin.isRetired)
        XCTAssertFalse(WalletNetwork.signet.isRetired)
        XCTAssertTrue(WalletNetwork.ecash.isRetired)       // alphanet
        XCTAssertTrue(WalletNetwork.ecashBeta.isRetired)   // betanet
        XCTAssertTrue(WalletNetwork.thunder.isRetired)     // Thunder betanet: its parent is retired
    }

    func testAccountIdAndStoreNames() {
        XCTAssertEqual(WalletAccount.accountId(network: WalletNetwork.ecashMainnet, scriptType: ScriptType.bip84, accountIndex: Int32(0)),
                       "ecashMainnet-bip84-0")
        XCTAssertEqual(WalletAccount.legacyStoreName(walletId: "w", network: WalletNetwork.signet), "w-signet.sqlite")
        XCTAssertEqual(WalletAccount.storeName(walletId: "w", network: WalletNetwork.bitcoin, scriptType: ScriptType.bip86, accountIndex: Int32(0)),
                       "w-bitcoin-bip86-0.sqlite")
    }

    func testLegacyInitBuildsOneAccountWithTheLegacyStore() {
        let w = ManagedWallet(id: "w1", label: "Main", network: WalletNetwork.ecashMainnet,
                              externalDescriptor: ext, internalDescriptor: int,
                              scriptType: ScriptType.bip84, accountIndex: Int32(0), isBackedUp: true, sortIndex: 2)
        XCTAssertEqual(w.accounts.count, 1)
        XCTAssertEqual(w.selectedAccountId, "ecashMainnet-bip84-0")
        XCTAssertEqual(w.selectedAccount.storeName, "w1-ecashMainnet.sqlite")   // what makePersister uses today
        XCTAssertTrue(w.mergedFrom.isEmpty)
        XCTAssertTrue(w.orphanKeychainIds.isEmpty)
        // Read-throughs match the account, so every existing caller sees the same values.
        XCTAssertEqual(w.network, WalletNetwork.ecashMainnet)
        XCTAssertEqual(w.externalDescriptor, ext)
        XCTAssertEqual(w.internalDescriptor, int)
        XCTAssertEqual(w.scriptType, ScriptType.bip84)
        XCTAssertEqual(w.accountIndex, Int32(0))
        XCTAssertEqual(w.derivationPath(isChange: false, index: Int32(3)), "m/84'/0'/0'/0/3")
        XCTAssertEqual(w.masterFingerprint, "d34db33f")
    }

    func testReadThroughsFollowTheSelectedAccount() {
        let ecash = WalletAccount(network: WalletNetwork.ecashMainnet, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                                  externalDescriptor: ext, internalDescriptor: int, storeName: "w-ecashMainnet.sqlite")
        let signet = WalletAccount(network: WalletNetwork.signet, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                                   externalDescriptor: "wpkh([d34db33f/84'/1'/0']tpubD/0/*)",
                                   internalDescriptor: "wpkh([d34db33f/84'/1'/0']tpubD/1/*)",
                                   storeName: "w-signet-bip84-0.sqlite")
        var w = ManagedWallet(id: "w", label: "Main", keyType: WalletKeyType.mnemonic, isBackedUp: false, sortIndex: 0,
                              selectedAccountId: ecash.id, accounts: [ecash, signet])
        XCTAssertEqual(w.network, WalletNetwork.ecashMainnet)
        XCTAssertEqual(w.derivationPath(isChange: true, index: Int32(0)), "m/84'/0'/0'/1/0")

        w.selectedAccountId = signet.id
        XCTAssertEqual(w.network, WalletNetwork.signet)
        XCTAssertEqual(w.externalDescriptor, signet.externalDescriptor)
        XCTAssertEqual(w.derivationPath(isChange: false, index: Int32(7)), "m/84'/1'/0'/0/7")
        XCTAssertEqual(w.account(id: ecash.id), ecash)
        XCTAssertNil(w.account(id: "nope"))
    }

    func testStaleSelectionFallsBackToTheFirstAccount() {
        let a = WalletAccount(network: WalletNetwork.bitcoin, scriptType: ScriptType.bip84, accountIndex: Int32(0),
                              externalDescriptor: ext, internalDescriptor: int, storeName: "s")
        let w = ManagedWallet(id: "w", label: "", keyType: WalletKeyType.mnemonic, isBackedUp: false, sortIndex: 0,
                              selectedAccountId: "gone", accounts: [a])
        XCTAssertEqual(w.selectedAccount, a)
        XCTAssertEqual(w.network, WalletNetwork.bitcoin)
    }

    func testWifWalletHasNoDerivationPath() {
        let w = ManagedWallet(id: "k", label: "Claim", network: WalletNetwork.ecashMainnet,
                              externalDescriptor: "pkh(02ab)", internalDescriptor: "pkh(02ab)",
                              keyType: WalletKeyType.wif)
        XCTAssertNil(w.derivationPath(isChange: false, index: Int32(0)))
        XCTAssertNil(w.selectedAccount.derivationPath(isChange: false, index: Int32(0)))   // no origin either way
        XCTAssertNil(w.masterFingerprint)
    }

    func testSidechainsNestUnderTheirParent() {
        XCTAssertEqual(WalletNetwork.thunder.parentChain, WalletNetwork.ecashBeta)
        XCTAssertTrue(WalletNetwork.thunder.isSidechain)
        for n in [WalletNetwork.ecashMainnet, WalletNetwork.bitcoin, WalletNetwork.signet, WalletNetwork.ecash, WalletNetwork.ecashBeta] {
            XCTAssertNil(n.parentChain, "\(n) is a mainchain")
            XCTAssertFalse(n.isSidechain)
        }
        XCTAssertEqual(WalletNetwork.sidechains(of: WalletNetwork.ecashBeta), [WalletNetwork.thunder])
        XCTAssertTrue(WalletNetwork.sidechains(of: WalletNetwork.bitcoin).isEmpty)
        XCTAssertTrue(WalletNetwork.sidechains(of: WalletNetwork.ecashMainnet).isEmpty)   // until a Thunder mainnet entry exists
    }

    func testKeyFamilyIsPublicAndUnchanged() {
        XCTAssertEqual(WalletNetwork.ecashMainnet.keyFamily, WalletNetwork.bitcoin.keyFamily)
        XCTAssertNil(WalletNetwork.signet.keyFamily)
        XCTAssertNil(WalletNetwork.thunder.keyFamily)
    }
}
