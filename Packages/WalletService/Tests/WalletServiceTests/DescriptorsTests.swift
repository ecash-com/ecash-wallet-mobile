// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// BIP84 derivation-path correctness per network (Golden Rule §4 / §6). Coin-type 0' on
/// mainnet, 1' on every test network — asserted against fixed vectors so a regression that
/// crossed mainnet and testnet derivation would fail loudly.
final class DescriptorsTests: XCTestCase {

    // Enum cases are written out in full (`WalletNetwork.bitcoin`, `Descriptors.Keychain.external`)
    // rather than as leading-dot shorthand: the Skip transpiler can't always infer the owning type
    // of a shorthand argument when the target overload has a defaulted parameter (`account:`), and
    // fails the transpile with "unable to determine the owning type for member". Explicit qualifying
    // is the documented workaround and reads fine here.
    func testAccountPathPerNetwork() {
        XCTAssertEqual(Descriptors.accountPath(for: WalletNetwork.bitcoin),  "m/84'/0'/0'")
        XCTAssertEqual(Descriptors.accountPath(for: WalletNetwork.signet),   "m/84'/1'/0'")
    }

    func testAccountPathWithAccountIndex() {
        XCTAssertEqual(Descriptors.accountPath(for: WalletNetwork.bitcoin, account: Int32(2)), "m/84'/0'/2'")
    }

    func testKeychainPathExternalVsChange() {
        XCTAssertEqual(Descriptors.keychainPath(for: WalletNetwork.signet, keychain: Descriptors.Keychain.external), "m/84'/1'/0'/0/*")
        XCTAssertEqual(Descriptors.keychainPath(for: WalletNetwork.signet, keychain: Descriptors.Keychain.change),   "m/84'/1'/0'/1/*")
    }

    func testMainnetAndTestnetPathsDiffer() {
        XCTAssertNotEqual(Descriptors.keychainPath(for: WalletNetwork.bitcoin, keychain: Descriptors.Keychain.external),
                          Descriptors.keychainPath(for: WalletNetwork.signet, keychain: Descriptors.Keychain.external))
    }

    func testWpkhWrapper() {
        XCTAssertEqual(Descriptors.wpkh("KEY"), "wpkh(KEY)")
    }

    // MARK: - What can be created vs imported

    /// Legacy and nested segwit are import-only. A fresh wallet has no coins at `1…` or `3…`
    /// addresses, so creating one there buys nothing — but someone recovering an old wallet must be
    /// able to match the address kind their coins live at, so `allCases` (which import uses) keeps
    /// both.
    func testLegacyAndNestedSegwitCanBeImportedButNotCreated() {
        for type in [ScriptType.bip44, ScriptType.bip49] {
            XCTAssertFalse(ScriptType.creatable.contains(type), "\(type) must not be creatable")
            XCTAssertTrue(ScriptType.allCases.contains(type), "\(type) must still be importable")
        }
    }

    /// The first creatable entry is what a picker shows by default, so it has to be native segwit.
    func testNativeSegwitIsTheDefaultOfferedAtCreate() {
        XCTAssertEqual(ScriptType.creatable.first, ScriptType.bip84)
    }

    /// New wallets get native segwit or taproot, nothing else.
    func testOnlySegwitAndTaprootAreCreatable() {
        XCTAssertEqual(ScriptType.creatable, [ScriptType.bip84, ScriptType.bip86])
    }
}
