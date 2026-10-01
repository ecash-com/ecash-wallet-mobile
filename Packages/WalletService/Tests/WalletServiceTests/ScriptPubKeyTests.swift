// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Address → scriptPubKey through real bdk-swift (host only, like BDKWalletEngineTests). This is the
// mainchain destination a Thunder withdrawal signs, so it's pinned to PUBLISHED vectors: BIP173's
// P2WPKH example and the well-known P2PKH address 1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2.
//
// SkipUnit lacks `XCTAssertThrowsError`; throwing expectations use do/catch.

import XCTest
import Foundation
@testable import WalletService

final class ScriptPubKeyTests: XCTestCase {
    private func factory() -> BDKWalletEngineFactory {
        BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("spk-test-\(UUID().uuidString)", isDirectory: true))
    }

    func testP2WPKHMatchesBIP173() throws {
        #if SKIP
        throw XCTSkip("real BDK — host only")
        #else
        // eCash uses Bitcoin's exact address format, so the Bitcoin vectors hold on `.ecashBeta`.
        XCTAssertEqual(try factory().scriptPubKeyHex("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", network: .ecashBeta),
                       "0014751e76e8199196d454941c45d1b3a323f1433bd6")
        #endif
    }

    func testP2PKH() throws {
        #if SKIP
        throw XCTSkip("real BDK — host only")
        #else
        XCTAssertEqual(try factory().scriptPubKeyHex("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", network: .ecashBeta),
                       "76a91477bff20c60e522dfaa3350c39b030a5d004e839a88ac")
        #endif
    }

    /// A testnet address must never become a withdrawal destination on eCash — the coins would pay a
    /// script on a chain whose owner was expecting test coins.
    func testRejectsAnotherNetworksAddressAndBadChecksums() throws {
        #if SKIP
        throw XCTSkip("real BDK — host only")
        #else
        for bad in ["tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",      // BIP173 testnet vector
                    "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5",      // checksum broken
                    "not an address", ""] {
            do {
                _ = try factory().scriptPubKeyHex(bad, network: .ecashBeta)
                XCTFail("accepted \(bad)")
            } catch let error as WalletError {
                XCTAssertEqual(error, .invalidAddress)
            }
        }
        #endif
    }
}
