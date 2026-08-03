// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// Rebuilding history from `get_utxos` + `get_stxos`. The node has no address-scoped history RPC, so
/// the netting done here IS the history — if it's wrong, the Activity list is wrong.
@Suite struct ThunderHistoryTests {

    private static let addressA = "38VvRdmcQREr1UAcZma98WLFVpAp"

    private static func txid(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    /// An unspent output paid to us by `fromTxid`.
    private static func utxo(from byte: UInt8, vout: UInt32 = 0, sats: UInt64) throws -> ThunderRPCPointedOutput {
        let json = """
        {"outpoint":{"Regular":{"txid":"\(txid(byte))","vout":\(vout)}},
         "output":{"address":"\(addressA)","content":{"Value":\(sats)}}}
        """
        return try JSONDecoder().decode(ThunderRPCPointedOutput.self, from: Data(json.utf8))
    }

    /// An output paid to us by `fromTxid` and later spent by `spentByTxid`.
    private static func stxo(from byte: UInt8, vout: UInt32 = 0, sats: UInt64,
                             spentBy spentByte: UInt8, vin: UInt32 = 0) throws -> ThunderRPCPointedSpentOutput {
        let json = """
        {"outpoint":{"Regular":{"txid":"\(txid(byte))","vout":\(vout)}},
         "output":{"output":{"address":"\(addressA)","content":{"Value":\(sats)}},
                   "inpoint":{"Regular":{"txid":"\(txid(spentByte))","vin":\(vin)}}}}
        """
        return try JSONDecoder().decode(ThunderRPCPointedSpentOutput.self, from: Data(json.utf8))
    }

    // MARK: - Decoding the new shapes

    /// `Pointed<SpentOutput>` nests: Pointed's field is named `output` whatever it holds, so a spent
    /// entry is `{"outpoint":…, "output":{"output":…, "inpoint":…}}`.
    @Test func decodesPointedSpentOutput() throws {
        let entry = try Self.stxo(from: 0x11, sats: 5_000, spentBy: 0x22)
        #expect(entry.outpoint.outPoint == .regular(txid: [UInt8](repeating: 0x11, count: 32), vout: 0))
        #expect(entry.output.output.content.valueSats == 5_000)
        #expect(entry.output.inpoint == .regular(txid: [UInt8](repeating: 0x22, count: 32), vin: 0))
    }

    @Test func decodesWithdrawalInpoint() throws {
        let json = """
        {"outpoint":{"Regular":{"txid":"\(Self.txid(0x11))","vout":0}},
         "output":{"output":{"address":"\(Self.addressA)","content":{"Value":10}},
                   "inpoint":{"Withdrawal":{"m6id":"aa"}}}}
        """
        let entry = try JSONDecoder().decode(ThunderRPCPointedSpentOutput.self, from: Data(json.utf8))
        #expect(entry.output.inpoint == .withdrawal(m6idHex: "aa"))
    }

    // MARK: - Netting

    /// A pure receive: one tx paid us, nothing spent.
    @Test func receiveIsPositive() throws {
        let txs = ThunderHistory.build(utxos: [try Self.utxo(from: 0x11, sats: 50_000)],
                                       stxos: [], firstSeen: [:])
        #expect(txs.count == 1)
        #expect(txs[0].txid == Self.txid(0x11))
        #expect(txs[0].netSats == 50_000)
        #expect(txs[0].isReceived)
    }

    /// The case `get_utxos` alone cannot see: tx 0x11 paid us, then tx 0x22 spent it and returned
    /// change. Without the stxo read, the spend would be invisible entirely.
    @Test func spendNetsAgainstItsChange() throws {
        let txs = ThunderHistory.build(
            utxos: [try Self.utxo(from: 0x22, sats: 30_000)],                     // change from the spend
            stxos: [try Self.stxo(from: 0x11, sats: 100_000, spentBy: 0x22)],     // the coin it consumed
            firstSeen: [Self.txid(0x11): 100, Self.txid(0x22): 200])

        #expect(txs.count == 2)
        let receive = try #require(txs.first { $0.txid == Self.txid(0x11) })
        let spend = try #require(txs.first { $0.txid == Self.txid(0x22) })
        #expect(receive.netSats == 100_000)
        #expect(spend.netSats == -70_000)      // 30,000 back − 100,000 consumed
        #expect(!spend.isReceived)
    }

    /// A self-transfer (split/sweep) — every input and output ours — nets to the fee. That's what
    /// `WalletTx.isSelfTransfer` keys off, so it must survive reconstruction.
    @Test func selfTransferNetsToTheFee() throws {
        let txs = ThunderHistory.build(
            utxos: [try Self.utxo(from: 0x22, sats: 99_800)],
            stxos: [try Self.stxo(from: 0x11, sats: 100_000, spentBy: 0x22)],
            firstSeen: [:])
        let split = try #require(txs.first { $0.txid == Self.txid(0x22) })
        #expect(split.netSats == -200)          // the fee
        #expect(split.receivedSats == 99_800)   // …and what actually moved
    }

    /// Several coins consumed by one transaction must aggregate, not overwrite.
    @Test func multipleInputsAggregate() throws {
        let txs = ThunderHistory.build(
            utxos: [],
            stxos: [try Self.stxo(from: 0x11, vout: 0, sats: 10_000, spentBy: 0x33, vin: 0),
                    try Self.stxo(from: 0x11, vout: 1, sats: 25_000, spentBy: 0x33, vin: 1)],
            firstSeen: [:])
        let receive = try #require(txs.first { $0.txid == Self.txid(0x11) })
        let spend = try #require(txs.first { $0.txid == Self.txid(0x33) })
        #expect(receive.netSats == 35_000)      // both outputs came from 0x11
        #expect(spend.netSats == -35_000)       // and 0x33 took both
    }

    // MARK: - What we deliberately don't claim

    /// Everything visible in the node's STATE is in a connected block, so it's confirmed — but the
    /// node exposes no height, so depth is unknown. `confirmations: 1` is a truthful floor and
    /// `blockHeight: nil` is the signal the UI reads as "confirmed, depth unknown".
    @Test func confirmedButDepthUnknown() throws {
        let tx = ThunderHistory.build(utxos: [try Self.utxo(from: 0x11, sats: 1)],
                                       stxos: [], firstSeen: [:])[0]
        #expect(tx.confirmations == 1)
        #expect(tx.blockHeight == nil)
        #expect(tx.isConfirmed)
    }

    /// The fee is NOT derivable: it's value_in − value_out across the whole transaction, and we only
    /// see the parts touching our own addresses. Claiming one would be a fabricated number.
    @Test func feeIsNotClaimed() throws {
        let txs = ThunderHistory.build(
            utxos: [try Self.utxo(from: 0x22, sats: 30_000)],
            stxos: [try Self.stxo(from: 0x11, sats: 100_000, spentBy: 0x22)],
            firstSeen: [:])
        #expect(txs.allSatisfy { $0.feeSats == nil })
    }

    /// Coinbase and mainchain-deposit outputs weren't created by any Thunder transaction, so there's
    /// no txid to attribute them to. Skipped rather than invented.
    @Test func outputsWithoutAThunderTxidAreSkipped() throws {
        let coinbase = """
        [{"outpoint":{"Coinbase":{"merkle_root":"\(Self.txid(0x33))","vout":0}},
          "output":{"address":"\(Self.addressA)","content":{"Value":7}}},
         {"outpoint":{"Deposit":{"txid":"\(Self.txid(0x44))","vout":0}},
          "output":{"address":"\(Self.addressA)","content":{"Value":9}}}]
        """
        let utxos = try JSONDecoder().decode([ThunderRPCPointedOutput].self, from: Data(coinbase.utf8))
        #expect(ThunderHistory.build(utxos: utxos, stxos: [], firstSeen: [:]).isEmpty)
    }

    /// Ordering falls back to first-seen while the node reports no height: newest first.
    @Test func ordersByFirstSeenNewestFirst() throws {
        let txs = ThunderHistory.build(
            utxos: [try Self.utxo(from: 0x11, sats: 1), try Self.utxo(from: 0x22, sats: 2)],
            stxos: [],
            firstSeen: [Self.txid(0x11): 100, Self.txid(0x22): 900])
        #expect(txs.map(\.txid) == [Self.txid(0x22), Self.txid(0x11)])
    }
}
