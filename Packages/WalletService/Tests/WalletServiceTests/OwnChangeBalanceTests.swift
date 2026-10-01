// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import WalletService

// Real-BDK, host only (like DepositEngineTests): builds BDK objects directly, so it's excluded from
// the transpile entirely.
#if !SKIP
import BitcoinDevKit

/// Regression (betanet tester, 2026-10-01): "sending from the wallet makes it look as though the entire
/// balance is pending". A single-key (WIF) wallet has no change keychain, so its change returns to its
/// one EXTERNAL address; BDK's `trustedPending` only trusts the internal keychain, so the change landed
/// in `untrustedPending` and the wallet showed everything as pending — while `send` (correctly) would
/// spend it. The balance must use the spend policy's rule: an unconfirmed output of a tx WE funded is
/// spendable; one from someone else is pending.
final class OwnChangeBalanceTests: XCTestCase {
    /// pkh(G): the secp256k1 generator as a compressed pubkey — any valid key will do for watch-only.
    private static let descriptor = "pkh(0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798)"

    private final class FixedChangeSet: Persistence, @unchecked Sendable {
        let changeSet: ChangeSet
        init(_ changeSet: ChangeSet) { self.changeSet = changeSet }
        func initialize() throws -> ChangeSet { changeSet }
        func persist(changeset: ChangeSet) throws {}
    }

    /// Legacy tx: version 2, empty scriptSigs, locktime 0.
    private static func rawTransaction(inputs: [(Data, UInt32)], outputs: [(UInt64, Data)]) -> Data {
        var bytes = Data([0x02, 0x00, 0x00, 0x00])
        bytes.append(UInt8(inputs.count))
        for (txid, vout) in inputs {
            bytes.append(txid)
            bytes.append(contentsOf: withUnsafeBytes(of: vout.littleEndian) { Array($0) })
            bytes.append(0x00)
            bytes.append(contentsOf: [0xff, 0xff, 0xff, 0xff])
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

    /// Internal txid bytes (what a spending input references) from BDK's display-order txid.
    private static func internalBytes(_ txid: Txid) -> Data {
        let hex = "\(txid)"
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return Data(bytes.reversed())
    }

    func testSingleKeyChangeFromOurOwnSendIsSpendableNotPending() throws {
        let descriptor = try Descriptor(descriptor: Self.descriptor, network: .bitcoin)
        let scratch = try Wallet.createSingle(descriptor: descriptor, network: .bitcoin,
                                              persister: try Persister.newInMemory())
        let ourScript = scratch.revealNextAddress(keychain: .external).address.scriptPubkey().toBytes()
        let theirScript = Data([0x00, 0x14] + [UInt8](repeating: 0x42, count: 20))

        // One CONFIRMED coin of 5,000,000 at our single address.
        let funding = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Data(repeating: 0x11, count: 32), 0)], outputs: [(5_000_000, ourScript)]))
        let genesis = try BlockHash.fromString(hex: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
        let tip = try BlockHash.fromString(hex: String(repeating: "ab", count: 32))
        let tipBlock = BlockId(height: 970_000, hash: tip)
        let changeSet = ChangeSet.fromAggregate(
            descriptor: descriptor, changeDescriptor: nil, network: .bitcoin,
            localChain: LocalChainChangeSet(changes: [ChainChange(height: 0, hash: genesis),
                                                      ChainChange(height: 970_000, hash: tip)]),
            txGraph: TxGraphChangeSet(
                txs: [funding], txouts: [:],
                anchors: [Anchor(confirmationBlockTime: ConfirmationBlockTime(blockId: tipBlock, confirmationTime: 1_790_000_000),
                                 txid: funding.computeTxid())],
                lastSeen: [:], firstSeen: [:], lastEvicted: [:]),
            indexer: IndexerChangeSet(lastRevealed: [descriptor.descriptorId(): 0]))
        let wallet = try Wallet.loadSingle(descriptor: descriptor,
                                           persister: Persister.custom(persistence: FixedChangeSet(changeSet)))
        let engine = WalletEngine(wallet: wallet, persister: try Persister.newInMemory(), network: .ecashBeta,
                                  backend: WalletBackend(kind: .esplora, url: "https://example.invalid"),
                                  signPsbt: { _ in false })
        XCTAssertEqual(try engine.balance(), Amount(sats: 5_000_000))

        // We send 1,000,000 away; 3,990,000 change comes back to the SAME (external) address,
        // unconfirmed — exactly what a WIF wallet's send produces.
        let send = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Self.internalBytes(funding.computeTxid()), 0)],
            outputs: [(1_000_000, theirScript), (3_990_000, ourScript)]))
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: send, lastSeen: 1_790_000_100)])

        XCTAssertEqual(try engine.balance(), Amount(sats: 3_990_000), "our own change is spendable")
        XCTAssertEqual(try engine.pendingBalance(), Amount(sats: 0), "nothing of ours is 'pending'")

        // Someone ELSE pays us 250,000, unconfirmed: that one IS pending, and stays out of the balance.
        let incoming = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Data(repeating: 0x33, count: 32), 7)], outputs: [(250_000, ourScript)]))
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: incoming, lastSeen: 1_790_000_200)])

        XCTAssertEqual(try engine.balance(), Amount(sats: 3_990_000))
        XCTAssertEqual(try engine.pendingBalance(), Amount(sats: 250_000))
    }
}
#endif
