// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import WalletService

/// BIP300 deposit detection (`Drivechain`). Pure byte logic with no BDK, so unlike the CoinNews
/// classifier tests these run on BOTH platforms: the host run and the transpiled-Kotlin
/// (Robolectric) run.
///
/// The fixture is a real betanet deposit, `f83c5c7a975798aefa35a98299b31bebcf4dda5edf885bd6f893244a1b2688c5`
/// (block 970,642), whose outputs are:
///   0  b7 01 09 51                          OP_NOP8 PUSHBYTES_1 09 OP_TRUE   (Thunder treasury)
///   1  6a 1b "8twUkpctzwgbjqi5o14qWjrD9uk"  OP_RETURN, the bare Thunder address
///   2  00 14 <20 bytes>                     P2WPKH change
final class DrivechainTests: XCTestCase {

    private let treasury = "b7010951"
    private let addressReturn = "6a1b387477556b7063747a7767626a7169356f313471576a724439756b"
    private let change = "00143cfff0edf887c48600221ff4a325abb23d97e6b8"

    /// Hex → bytes, by hand: `UInt8(_:radix:)` doesn't transpile to Kotlin.
    private func hex(_ s: String) -> Data {
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
        var chars: [Character] = []
        for c in s.lowercased() { chars.append(c) }
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < chars.count {
            let high = digits.firstIndex(of: chars[i]) ?? 0
            let low = digits.firstIndex(of: chars[i + 1]) ?? 0
            bytes.append(UInt8(high * 16 + low))
            i += 2
        }
        return Data(bytes)
    }

    // MARK: - The real betanet deposit

    func testRealBetanetDeposit() {
        let scripts = [hex(treasury), hex(addressReturn), hex(change)]
        let deposit = Drivechain.deposit(inOutputScripts: scripts, opcode: UInt8(0xb7))
        XCTAssertEqual(deposit?.slot, Int32(9))
        XCTAssertEqual(deposit?.address, "8twUkpctzwgbjqi5o14qWjrD9uk")
    }

    func testBetanetDepositIsNotReadWithAlphanetsOpcode() {
        // Same bytes under OP_NOP5 aren't a treasury: each network's opcode is its own.
        let scripts = [hex(treasury), hex(addressReturn), hex(change)]
        XCTAssertNil(Drivechain.deposit(inOutputScripts: scripts, opcode: UInt8(0xb4)))
    }

    func testDepositNeedNotBeAtOutputZero() {
        // Change first is still valid: the rule is "address right after the treasury".
        let scripts = [hex(change), hex(treasury), hex(addressReturn)]
        XCTAssertEqual(Drivechain.deposit(inOutputScripts: scripts, opcode: UInt8(0xb7))?.slot, Int32(9))
    }

    func testAddressMustImmediatelyFollowTreasury() {
        // The enforcer rejects this shape (MissingDepositAddress), so it must not be labelled.
        let scripts = [hex(treasury), hex(change), hex(addressReturn)]
        XCTAssertNil(Drivechain.deposit(inOutputScripts: scripts, opcode: UInt8(0xb7)))
    }

    func testTreasuryAsLastOutputIsNotADeposit() {
        XCTAssertNil(Drivechain.deposit(inOutputScripts: [hex(change), hex(treasury)], opcode: UInt8(0xb7)))
    }

    func testWithdrawalPayoutIsNotADeposit() {
        // M6: new treasury at vout 0, then payouts. No address OP_RETURN after it.
        let scripts = [hex(treasury), hex(change), hex(change)]
        XCTAssertNil(Drivechain.deposit(inOutputScripts: scripts, opcode: UInt8(0xb7)))
    }

    func testOrdinaryTransactionIsNotADeposit() {
        XCTAssertNil(Drivechain.deposit(inOutputScripts: [hex(change), hex(change)], opcode: UInt8(0xb7)))
        XCTAssertNil(Drivechain.deposit(inOutputScripts: [], opcode: UInt8(0xb7)))
    }

    // MARK: - Treasury script

    func testTreasurySlots() {
        XCTAssertEqual(Drivechain.treasurySlot(fromScript: hex("b7010951"), opcode: UInt8(0xb7)), Int32(9))
        XCTAssertEqual(Drivechain.treasurySlot(fromScript: hex("b4010051"), opcode: UInt8(0xb4)), Int32(0))
        // Slot 255 must come back as 255, not -1: the slot byte is unsigned.
        XCTAssertEqual(Drivechain.treasurySlot(fromScript: hex("b701ff51"), opcode: UInt8(0xb7)), Int32(255))
    }

    func testTreasuryShapeIsExact() {
        XCTAssertNil(Drivechain.treasurySlot(fromScript: hex("b701095100"), opcode: UInt8(0xb7)))   // trailing byte
        XCTAssertNil(Drivechain.treasurySlot(fromScript: hex("b70109"), opcode: UInt8(0xb7)))       // truncated
        XCTAssertNil(Drivechain.treasurySlot(fromScript: hex("b7020951"), opcode: UInt8(0xb7)))     // not PUSHBYTES_1
        XCTAssertNil(Drivechain.treasurySlot(fromScript: hex("b7010900"), opcode: UInt8(0xb7)))     // not OP_TRUE
    }

    // MARK: - Address OP_RETURN

    func testAddressDirectPush() {
        XCTAssertEqual(Drivechain.depositAddress(fromScript: hex(addressReturn)), "8twUkpctzwgbjqi5o14qWjrD9uk")
    }

    func testAddressPushData1() {
        // 80 bytes of "a" needs OP_PUSHDATA1 (0x4c) — longer sidechain address formats may.
        let body = String(repeating: "61", count: 80)
        XCTAssertEqual(Drivechain.depositAddress(fromScript: hex("6a4c50" + body)), String(repeating: "a", count: 80))
    }

    func testAddressPushData2() {
        let body = String(repeating: "62", count: 300)   // 300 = 0x012c, little-endian 2c 01
        XCTAssertEqual(Drivechain.depositAddress(fromScript: hex("6a4d2c01" + body)), String(repeating: "b", count: 300))
    }

    func testAddressRejectsExtraPushes() {
        // `OP_RETURN <push> <push>`: the enforcer requires exactly one push.
        XCTAssertNil(Drivechain.depositAddress(fromScript: hex("6a0161" + "0162")))
    }

    func testAddressRejectsTruncatedPush() {
        XCTAssertNil(Drivechain.depositAddress(fromScript: hex("6a0561")))
    }

    func testAddressRejectsEmptyPushAndNonOpReturn() {
        XCTAssertNil(Drivechain.depositAddress(fromScript: hex("6a00")))
        XCTAssertNil(Drivechain.depositAddress(fromScript: hex("6a")))
        XCTAssertNil(Drivechain.depositAddress(fromScript: hex(change)))
    }

    // MARK: - Per-network opcode

    func testOpcodePerNetwork() {
        XCTAssertEqual(Drivechain.opcode(for: WalletNetwork.ecashBeta), UInt8(0xb7))
        XCTAssertEqual(Drivechain.opcode(for: WalletNetwork.ecash), UInt8(0xb4))
        XCTAssertEqual(Drivechain.opcode(for: WalletNetwork.signet), UInt8(0xb4))
        XCTAssertNil(Drivechain.opcode(for: WalletNetwork.bitcoin))
        XCTAssertNil(Drivechain.opcode(for: WalletNetwork.thunder))
    }

    // MARK: - WalletTx surface

    func testWalletTxCarriesTheDeposit() {
        let tx = WalletTx(txid: "f83c", netSats: Int64(-10_000_450), feeSats: Int64(450), confirmations: Int32(3),
                          timestampEpochSeconds: nil, isRBF: true,
                          sidechainDepositSlot: Int32(9), sidechainDepositAddress: "8twUkpctzwgbjqi5o14qWjrD9uk")
        XCTAssertTrue(tx.isSidechainDeposit)
        XCTAssertFalse(tx.isSelfTransfer)   // the coins left the wallet
        let plain = WalletTx(txid: "a", netSats: Int64(5), feeSats: nil, confirmations: Int32(1),
                             timestampEpochSeconds: nil, isRBF: false)
        XCTAssertFalse(plain.isSidechainDeposit)
    }
}
