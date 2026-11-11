// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest
@testable import WalletService

// Real-BDK, host only (like OwnChangeBalanceTests): builds BDK objects directly, so it's excluded
// from the transpile entirely.
#if !SKIP
import BitcoinDevKit

/// The spend policy since 2026-11-11: incoming unconfirmed coins are spendable, but coin selection
/// reaches for them only when confirmed coins (plus our own change) don't cover the payment, and the
/// review's dry run reports exactly how much of the payment rides on them. A wallet with one confirmed
/// coin and one unconfirmed incoming payment pins every branch: a payment the confirmed coin covers
/// (no unconfirmed input), one it doesn't (the unconfirmed coin joins, and is reported), one nothing
/// covers (insufficient funds, not a silent fall-through), and Max (everything, reported).
final class UnconfirmedSpendTests: XCTestCase {
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

    private static let recipient = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"   // BIP173 test vector
    private static let confirmedSats: UInt64 = 5_000_000
    private static let incomingSats: UInt64 = 250_000

    private struct Fixture {
        let wallet: Wallet
        let engine: WalletEngine
        let ourScript: Data
        let confirmedTxid: Txid
        let incomingTxid: Txid
    }

    private func makeEngine() throws -> WalletEngine { try makeFixture().engine }

    /// One CONFIRMED coin of 5,000,000 and one UNCONFIRMED incoming payment of 250,000 (someone
    /// else's inputs), both at our single address.
    private func makeFixture() throws -> Fixture {
        let descriptor = try Descriptor(descriptor: Self.descriptor, network: .bitcoin)
        let scratch = try Wallet.createSingle(descriptor: descriptor, network: .bitcoin,
                                              persister: try Persister.newInMemory())
        let ourScript = scratch.revealNextAddress(keychain: .external).address.scriptPubkey().toBytes()

        let funding = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Data(repeating: 0x11, count: 32), 0)], outputs: [(Self.confirmedSats, ourScript)]))
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

        let incoming = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Data(repeating: 0x33, count: 32), 7)], outputs: [(Self.incomingSats, ourScript)]))
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: incoming, lastSeen: 1_790_000_200)])

        let engine = WalletEngine(wallet: wallet, persister: try Persister.newInMemory(), network: .ecashMainnet,
                                  backend: WalletBackend(kind: .esplora, url: "https://example.invalid"),
                                  signPsbt: { _ in false })
        return Fixture(wallet: wallet, engine: engine, ourScript: ourScript,
                       confirmedTxid: funding.computeTxid(), incomingTxid: incoming.computeTxid())
    }

    func testIncomingUnconfirmedCountsInBalanceAndIsReportedApart() throws {
        let engine = try makeEngine()
        XCTAssertEqual(try engine.balance(), Amount(sats: 5_250_000), "spendable now includes the incoming 0-conf")
        XCTAssertEqual(try engine.unconfirmedBalance(), Amount(sats: 250_000), "…and Home can say how much of it is that")
        XCTAssertEqual(try engine.pendingBalance(), Amount(sats: 0), "nothing is unspendable (no immature coinbase)")
    }

    func testPaymentCoveredByConfirmedCoinsSpendsNoUnconfirmedInput() throws {
        let preview = try makeEngine().previewSend(to: Self.recipient, amount: Amount(sats: 1_000_000),
                                                   feeRate: FeeRate(satPerVByte: 1))
        XCTAssertEqual(preview.unconfirmedInputSats, 0, "first pass succeeded: the 0-conf coin stays out")
        XCTAssertGreaterThan(preview.feeSats, 0)
    }

    func testPaymentNeedingTheUnconfirmedCoinReportsIt() throws {
        let preview = try makeEngine().previewSend(to: Self.recipient, amount: Amount(sats: 5_100_000),
                                                   feeRate: FeeRate(satPerVByte: 1))
        XCTAssertEqual(preview.unconfirmedInputSats, 250_000, "second pass: the 0-conf coin had to join, and the review hears about it")
        XCTAssertGreaterThan(preview.feeSats, 0)
    }

    func testPaymentNothingCoversIsInsufficientFundsNotASilentFallThrough() throws {
        do {
            _ = try makeEngine().previewSend(to: Self.recipient, amount: Amount(sats: 6_000_000),
                                             feeRate: FeeRate(satPerVByte: 1))
            XCTFail("expected insufficient funds")
        } catch let error as WalletError {
            guard case .insufficientFunds = error else { return XCTFail("expected insufficientFunds, got \(error)") }
        }
    }

    func testMaxTakesEverythingAndReportsTheUnconfirmedShare() throws {
        let preview = try makeEngine().previewSweep(to: Self.recipient, feeRate: FeeRate(satPerVByte: 1))
        XCTAssertEqual(preview.unconfirmedInputSats, 250_000)
        XCTAssertGreaterThan(preview.feeSats, 0)
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

    /// Seen on the sim the day this shipped: receive 0-conf, spend it, and the "of this is
    /// unconfirmed" line vanished — BDK files our send's change as trusted however it was funded. The
    /// change of a send that spent an incoming unconfirmed coin is only as good as that coin, so it
    /// stays unconfirmed (and warned about) until the coin confirms; change from a send funded by
    /// confirmed coins stays trusted.
    func testChangeFromSpendingTheUnconfirmedCoinStaysUnconfirmed() throws {
        let fixture = try makeFixture()
        let engine = fixture.engine
        let wallet = fixture.wallet
        let ourScript = fixture.ourScript
        let theirScript = Data([0x00, 0x14] + [UInt8](repeating: 0x42, count: 20))
        let incoming = fixture.incomingTxid
        let confirmed = fixture.confirmedTxid

        // We spend the 250,000 incoming coin: 200,000 away, 49,000 change back to us.
        let chained = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Self.internalBytes(incoming), 0)], outputs: [(200_000, theirScript), (49_000, ourScript)]))
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: chained, lastSeen: 1_790_000_300)])

        XCTAssertEqual(try engine.balance(), Amount(sats: 5_049_000))
        XCTAssertEqual(try engine.unconfirmedBalance(), Amount(sats: 49_000), "the change still rides on the sender's tx")
        let preview = try engine.previewSend(to: Self.recipient, amount: Amount(sats: 5_010_000),
                                             feeRate: FeeRate(satPerVByte: 1))
        XCTAssertEqual(preview.unconfirmedInputSats, 49_000, "…and the review says so when a send needs it")
        XCTAssertEqual(try engine.splitCandidates().map { $0.amount.sats }, [5_000_000], "split keeps it out")

        // A send funded by the CONFIRMED coin: its change is ours to trust, and the unconfirmed share
        // is unchanged by it.
        let clean = try Transaction(transactionBytes: Self.rawTransaction(
            inputs: [(Self.internalBytes(confirmed), 0)], outputs: [(1_000_000, theirScript), (3_990_000, ourScript)]))
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: clean, lastSeen: 1_790_000_400)])
        XCTAssertEqual(try engine.balance(), Amount(sats: 4_039_000))
        XCTAssertEqual(try engine.unconfirmedBalance(), Amount(sats: 49_000), "trusted change is not unconfirmed")
        XCTAssertEqual(try engine.previewSend(to: Self.recipient, amount: Amount(sats: 3_000_000),
                                              feeRate: FeeRate(satPerVByte: 1)).unconfirmedInputSats, 0)
    }

    func testSplitCandidatesStillExcludeTheUnconfirmedCoin() throws {
        // Bitcoin's explorer can't classify a coin that isn't in a block; the split path keeps the
        // strict rule so summary, candidates and the split tx agree on scope.
        let candidates = try makeEngine().splitCandidates()
        XCTAssertEqual(candidates.map { $0.amount.sats }, [5_000_000])
    }
}
#endif
