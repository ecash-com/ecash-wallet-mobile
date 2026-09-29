// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import WalletService

// Real-BDK, host only (like BDKWalletEngineTests): bdk-swift doesn't load under Robolectric, and
// this file builds BDK objects directly, so it's excluded from the transpile entirely.
#if !SKIP
import BitcoinDevKit

/// Sidechain deposits (BIP300 M5) built by the REAL engine against a real BDK wallet, no network.
///
/// The wallet is a watch-only (public-descriptor) BDK wallet loaded from a hand-built ChangeSet: a
/// local chain (genesis + a tip block) and one funding transaction anchored in that block, so it
/// holds a CONFIRMED coin the spend policy will use. Signing uses a separate private-descriptor
/// wallet, exactly as production's sign-on-demand does. The treasury's previous transaction is a
/// fake shaped like betanet's real one.
///
/// What this proves that the pure `DrivechainTests` can't:
/// - BDK accepts the treasury as a foreign input and the signer leaves its empty scriptSig alone
///   (the enforcer relies on the same thing and calls it "might be wrong, seems to work");
/// - the ordering retry finds a valid order and the result passes the shape check SIGNED;
/// - the treasury cross-check refuses every way the enforcer's claim can disagree with the chain.
final class DepositEngineTests: XCTestCase {

    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let thunderAddress = "8twUkpctzwgbjqi5o14qWjrD9uk"
    private static let betanetOpcode = UInt8(0xb7)

    /// A persister that hands BDK a fixed ChangeSet on load and discards writes.
    private final class FixedChangeSet: Persistence, @unchecked Sendable {
        let changeSet: ChangeSet
        init(_ changeSet: ChangeSet) { self.changeSet = changeSet }
        func initialize() throws -> ChangeSet { changeSet }
        func persist(changeset: ChangeSet) throws {}
    }

    private struct Fixture {
        let engine: WalletEngine
        let signer: Wallet
        let watchOnly: Wallet
    }

    /// A betanet wallet (`.ecashBeta` → BDK mainnet params) holding one confirmed coin of `sats`.
    private func makeFundedWallet(sats: UInt64 = 5_000_000) throws -> Fixture {
        let mnemonic = try Mnemonic.fromString(mnemonic: Self.mnemonic)
        let key = DescriptorSecretKey(network: .bitcoin, mnemonic: mnemonic, password: nil)
        let externalPrivate = Descriptor.newBip84(secretKey: key, keychainKind: .external, network: .bitcoin)
        let internalPrivate = Descriptor.newBip84(secretKey: key, keychainKind: .internal, network: .bitcoin)
        let externalPublic = try Descriptor(descriptor: externalPrivate.description, network: .bitcoin)
        let internalPublic = try Descriptor(descriptor: internalPrivate.description, network: .bitcoin)

        let scratch = try Wallet(descriptor: externalPublic, changeDescriptor: internalPublic,
                                 network: .bitcoin, persister: try Persister.newInMemory())
        let receiveScript = scratch.revealNextAddress(keychain: .external).address.scriptPubkey().toBytes()
        let funding = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Data(repeating: 0x11, count: 32), 0)],
            outputs: [(sats, receiveScript)]))

        let genesis = try BlockHash.fromString(hex: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
        let tip = try BlockHash.fromString(hex: String(repeating: "ab", count: 32))
        let tipBlock = BlockId(height: 970_000, hash: tip)
        let changeSet = ChangeSet.fromAggregate(
            descriptor: externalPublic, changeDescriptor: internalPublic, network: .bitcoin,
            localChain: LocalChainChangeSet(changes: [ChainChange(height: 0, hash: genesis),
                                                      ChainChange(height: 970_000, hash: tip)]),
            txGraph: TxGraphChangeSet(
                txs: [funding], txouts: [:],
                anchors: [Anchor(confirmationBlockTime: ConfirmationBlockTime(blockId: tipBlock, confirmationTime: 1_790_000_000),
                                 txid: funding.computeTxid())],
                lastSeen: [:], firstSeen: [:], lastEvicted: [:]),
            indexer: IndexerChangeSet(lastRevealed: [externalPublic.descriptorId(): 0]))
        let watchOnly = try Wallet.load(descriptor: externalPublic, changeDescriptor: internalPublic,
                                        persister: Persister.custom(persistence: FixedChangeSet(changeSet)))
        let signer = try Wallet(descriptor: externalPrivate, changeDescriptor: internalPrivate,
                                network: .bitcoin, persister: try Persister.newInMemory())
        let engine = WalletEngine(wallet: watchOnly, persister: try Persister.newInMemory(), network: .ecashBeta,
                                  backend: WalletBackend(kind: .esplora, url: "https://example.invalid"),
                                  signPsbt: { psbt in try signer.sign(psbt: psbt, signOptions: nil) })
        return Fixture(engine: engine, signer: signer, watchOnly: watchOnly)
    }

    /// A treasury's previous transaction: output `vout` pays `value` to slot `slot`'s treasury script.
    private func treasuryTransaction(slot: UInt8, value: UInt64, vout: Int = 0,
                                     opcode: UInt8 = DepositEngineTests.betanetOpcode) throws -> Transaction {
        var outputs: [(UInt64, Data)] = []
        for i in 0...vout {
            outputs.append(i == vout ? (value, Data([opcode, 0x01, slot, 0x51])) : (1_000, Data([0x6a, 0x01, 0x00])))
        }
        return try Transaction(transactionBytes: Self.rawTransaction(inputs: [(Data(repeating: 0x22, count: 32), 1)],
                                                                    outputs: outputs))
    }

    /// Serialize a legacy (non-segwit) transaction: version 2, empty scriptSigs, locktime 0.
    private static func rawTransaction(inputs: [(Data, UInt32)], outputs: [(UInt64, Data)]) -> Data {
        var bytes = Data([0x02, 0x00, 0x00, 0x00])
        bytes.append(UInt8(inputs.count))
        for (txid, vout) in inputs {
            bytes.append(txid)
            bytes.append(contentsOf: withUnsafeBytes(of: vout.littleEndian) { Array($0) })
            bytes.append(0x00)                                   // empty scriptSig
            bytes.append(contentsOf: [0xff, 0xff, 0xff, 0xff])   // sequence
        }
        bytes.append(UInt8(outputs.count))
        for (value, script) in outputs {
            bytes.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
            bytes.append(UInt8(script.count))
            bytes.append(script)
        }
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return bytes
    }

    private func sign(_ prepared: WalletEngine.PreparedDeposit, with fixture: Fixture) throws -> Transaction {
        let finalized = try fixture.signer.sign(psbt: prepared.psbt, signOptions: nil)
        XCTAssertTrue(finalized, "every input must finalize: ours signed, the treasury pre-finalized")
        return try prepared.psbt.extractTx()
    }

    private func expectError(_ expected: WalletError, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as WalletError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - Building

    func testFirstDepositToAnEmptySlot() throws {
        let f = try makeFundedWallet()
        let prepared = try f.engine.prepareDeposit(
            slot: 98, address: Self.thunderAddress, amount: Amount(sats: 100_000), feeRate: FeeRate(satPerVByte: 2),
            previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 0)
        let tx = try sign(prepared, with: f)

        XCTAssertTrue(f.engine.isExpectedDeposit(tx, prepared))
        let deposit = Drivechain.deposit(inOutputScripts: tx.output().map { $0.scriptPubkey.toBytes() },
                                         opcode: Self.betanetOpcode)
        XCTAssertEqual(deposit?.slot, 98)
        XCTAssertEqual(deposit?.address, Self.thunderAddress)
        let treasury = tx.output().first { $0.scriptPubkey.toBytes() == Data([0xb7, 0x01, 98, 0x51]) }
        XCTAssertEqual(treasury?.value.toSat(), 100_000)          // nothing to add to: the deposit IS the treasury
        XCTAssertEqual(tx.input().count, 1)                        // just our coin
    }

    func testDepositSpendsTheCurrentTreasury() throws {
        let f = try makeFundedWallet()
        let previous = try treasuryTransaction(slot: 9, value: 519_790_000)
        let treasuryTxid = "\(previous.computeTxid())"
        let prepared = try f.engine.prepareDeposit(
            slot: 9, address: Self.thunderAddress, amount: Amount(sats: 250_000), feeRate: FeeRate(satPerVByte: 3),
            previousTreasury: previous, treasuryTxid: treasuryTxid, treasuryVout: 0, treasuryValueSats: 519_790_000)
        let tx = try sign(prepared, with: f)

        XCTAssertTrue(f.engine.isExpectedDeposit(tx, prepared))
        // New treasury = old + deposit, and the address OP_RETURN sits right after it.
        let outputs = tx.output()
        let index = try XCTUnwrap(outputs.firstIndex { $0.scriptPubkey.toBytes() == Data([0xb7, 0x01, 0x09, 0x51]) })
        XCTAssertEqual(outputs[index].value.toSat(), 519_790_000 + 250_000)
        XCTAssertEqual(Drivechain.depositAddress(fromScript: outputs[index + 1].scriptPubkey.toBytes()), Self.thunderAddress)

        // The treasury is spent exactly once, with an EMPTY scriptSig and no witness: anyone-can-spend.
        let inputs = tx.input()
        let treasuryInputs = inputs.filter { "\($0.previousOutput.txid)" == treasuryTxid && $0.previousOutput.vout == 0 }
        XCTAssertEqual(treasuryInputs.count, 1)
        XCTAssertEqual(treasuryInputs.first?.scriptSig.toBytes(), Data())
        XCTAssertEqual(treasuryInputs.first?.witness ?? [], [])
        // Our own input IS signed (P2WPKH: signature + pubkey in the witness).
        let ours = inputs.filter { "\($0.previousOutput.txid)" != treasuryTxid }
        XCTAssertEqual(ours.count, 1)
        XCTAssertEqual(ours.first?.witness.count, 2)

        // eCash replay protection holds on a deposit too.
        XCTAssertEqual(tx.lockTime(), 499_999_999)
    }

    func testTreasuryAtANonZeroOutput() throws {
        let f = try makeFundedWallet()
        let previous = try treasuryTransaction(slot: 4, value: 133_074_500, vout: 2)
        let prepared = try f.engine.prepareDeposit(
            slot: 4, address: "someBitAssetsAddr", amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
            previousTreasury: previous, treasuryTxid: "\(previous.computeTxid())", treasuryVout: 2,
            treasuryValueSats: 133_074_500)
        XCTAssertTrue(f.engine.isExpectedDeposit(try sign(prepared, with: f), prepared))
    }

    func testRepeatedBuildsDontBurnChangeAddresses() throws {
        // Every rejected (mis-ordered) build is cancelled. Ten deposits' worth of building must leave
        // the internal keychain's next address where a single build would.
        let f = try makeFundedWallet()
        for _ in 0..<10 {
            let prepared = try f.engine.prepareDeposit(
                slot: 98, address: Self.thunderAddress, amount: Amount(sats: 50_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 0)
            f.watchOnly.cancelTx(tx: try prepared.psbt.extractTx())
        }
        let next = f.watchOnly.nextUnusedAddress(keychain: .internal)
        XCTAssertLessThan(next.index, 2, "abandoned builds must not reveal fresh change addresses")
    }

    // MARK: - Refusals: the enforcer's claim must match the chain

    func testRefusesATreasuryFromAnotherTransaction() throws {
        let f = try makeFundedWallet()
        let previous = try treasuryTransaction(slot: 9, value: 1_000_000)
        expectError(.sidechainTreasuryMismatch) {
            _ = try f.engine.prepareDeposit(
                slot: 9, address: Self.thunderAddress, amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: previous, treasuryTxid: String(repeating: "cd", count: 32), treasuryVout: 0,
                treasuryValueSats: 1_000_000)
        }
    }

    func testRefusesAWrongTreasuryValue() throws {
        // Building on a wrong value would write a wrong new treasury: the enforcer would reject the
        // block's deposit, or worse, credit the wrong amount.
        let f = try makeFundedWallet()
        let previous = try treasuryTransaction(slot: 9, value: 1_000_000)
        expectError(.sidechainTreasuryMismatch) {
            _ = try f.engine.prepareDeposit(
                slot: 9, address: Self.thunderAddress, amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: previous, treasuryTxid: "\(previous.computeTxid())", treasuryVout: 0,
                treasuryValueSats: 999_999)
        }
    }

    func testRefusesAnotherSlotsTreasury() throws {
        let f = try makeFundedWallet()
        let bitnames = try treasuryTransaction(slot: 2, value: 1_000_000)
        expectError(.sidechainTreasuryMismatch) {
            _ = try f.engine.prepareDeposit(
                slot: 9, address: Self.thunderAddress, amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: bitnames, treasuryTxid: "\(bitnames.computeTxid())", treasuryVout: 0,
                treasuryValueSats: 1_000_000)
        }
    }

    func testRefusesAnotherNetworksOpcode() throws {
        // Alphanet's NOP5 treasury is not a betanet treasury, whatever the enforcer says.
        let f = try makeFundedWallet()
        let alphanetStyle = try treasuryTransaction(slot: 9, value: 1_000_000, opcode: 0xb4)
        expectError(.sidechainTreasuryMismatch) {
            _ = try f.engine.prepareDeposit(
                slot: 9, address: Self.thunderAddress, amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: alphanetStyle, treasuryTxid: "\(alphanetStyle.computeTxid())", treasuryVout: 0,
                treasuryValueSats: 1_000_000)
        }
    }

    func testRefusesAValueForASlotWithNoTreasury() throws {
        let f = try makeFundedWallet()
        expectError(.sidechainTreasuryMismatch) {
            _ = try f.engine.prepareDeposit(
                slot: 98, address: Self.thunderAddress, amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 5)
        }
    }

    // MARK: - Refusals: inputs

    func testRefusesTheWrappedDisplayAddress() throws {
        // `s9_<addr>_<checksum>` in the OP_RETURN credits an address nobody controls.
        let f = try makeFundedWallet()
        expectError(.invalidSidechainAddress) {
            _ = try f.engine.prepareDeposit(
                slot: 9, address: "s9_\(Self.thunderAddress)_a1b2c3", amount: Amount(sats: 10_000),
                feeRate: FeeRate(satPerVByte: 1), previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 0)
        }
        expectError(.invalidSidechainAddress) {
            _ = try f.engine.prepareDeposit(
                slot: 9, address: "", amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 0)
        }
    }

    func testRefusesAnOutOfRangeSlotAndZeroAmount() throws {
        let f = try makeFundedWallet()
        expectError(.sidechainNotSupported) {
            _ = try f.engine.prepareDeposit(
                slot: 256, address: Self.thunderAddress, amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 0)
        }
        expectError(.dustAmount) {
            _ = try f.engine.prepareDeposit(
                slot: 9, address: Self.thunderAddress, amount: Amount(sats: 0), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 0)
        }
    }

    func testRefusesMoreThanTheWalletHolds() throws {
        let f = try makeFundedWallet(sats: 50_000)
        expectError(.insufficientFunds) {
            _ = try f.engine.prepareDeposit(
                slot: 98, address: Self.thunderAddress, amount: Amount(sats: 60_000), feeRate: FeeRate(satPerVByte: 1),
                previousTreasury: nil, treasuryTxid: nil, treasuryVout: 0, treasuryValueSats: 0)
        }
    }
}
#endif
