// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The drivechain-esplora wire layer, and the mapping from one of its UTXO rows back to the domain
/// `ThunderPointedOutput` we sign against.
///
/// **That mapping is consensus-critical.** Every input carries `BLAKE3(borsh(PointedOutput))` as its
/// utreexo leaf hash, and the node proves against exactly that value — reconstruct the outpoint or the
/// output wrongly and the node proves the wrong leaf and rejects the transaction. So the load-bearing
/// test here is `esploraAndRPCAgreeOnTheUtxoHash`: the two backends see the same coin described in two
/// different JSON shapes and must arrive at byte-identical hashes.
@Suite struct ThunderEsploraTypesTests {

    /// Index-0 address for the standard test mnemonic (pinned in ThunderWalletTests).
    private static let address = "38VvRdmcQREr1UAcZma98WLFVpAp"
    private static let txidHex = String(repeating: "11", count: 32)

    private static func utxo(_ json: String) throws -> ThunderEsploraUTXO {
        try JSONDecoder().decode(ThunderEsploraUTXO.self, from: Data(json.utf8))
    }

    private static func valueUTXO(txid: String = txidHex, vout: Int = 2, value: Int = 12345,
                                  kind: String = "regular",
                                  contentType: String = "value",
                                  height: Int = 100) -> String {
        """
        {"txid":"\(txid)","vout":\(vout),"value":\(value),
         "status":{"confirmed":true,"block_height":\(height),
                   "block_hash":"\(String(repeating: "ab", count: 32))","block_time":1750000000},
         "outpoint_kind":"\(kind)","height_exact":true,"content_type":"\(contentType)"}
        """
    }

    // MARK: - UTXO decoding and mapping

    @Test func decodesAValueUTXO() throws {
        let row = try Self.utxo(Self.valueUTXO())
        #expect(row.value == 12345)
        #expect(row.vout == 2)
        #expect(row.contentType == "value")
        #expect(row.status.confirmed)
        #expect(row.status.blockHeight == 100)
        #expect(row.status.blockTime == 1_750_000_000)

        let address = try #require(ThunderAddress(base58: Self.address))
        let pointed = try #require(row.pointedOutput(address: address))
        #expect(pointed.valueSats == 12345)
        #expect(pointed.address.base58 == Self.address)
        #expect(pointed.outPoint == .regular(txid: [UInt8](repeating: 0x11, count: 32), vout: 2))
    }

    @Test func coinbaseRowKeysOnTheMerkleRoot() throws {
        let row = try Self.utxo(Self.valueUTXO(txid: String(repeating: "cc", count: 32), kind: "coinbase"))
        #expect(row.outPoint() == .coinbase(merkleRoot: [UInt8](repeating: 0xcc, count: 32), vout: 2))
    }

    /// A deposit names a **mainchain** txid, which the index renders in Bitcoin's reversed display
    /// order. Borsh wants the internal bytes, so the mapping must flip it — and only for this variant.
    @Test func depositRowIsByteReversed() throws {
        var displayOrder = [UInt8](repeating: 0x00, count: 32)
        displayOrder[0] = 0xde
        displayOrder[31] = 0xad
        let hex = displayOrder.map { String(format: "%02x", $0) }.joined()

        let row = try Self.utxo(Self.valueUTXO(txid: hex, kind: "deposit"))
        let outPoint = try #require(row.outPoint())
        guard case let .deposit(txid, vout) = outPoint else {
            Issue.record("expected a deposit outpoint"); return
        }
        #expect(vout == 2)
        #expect(txid == displayOrder.reversed())
        #expect(txid.first == 0xad)   // the flip actually happened
        #expect(txid.last == 0xde)
    }

    /// A withdrawal is unspendable by consensus, and the index folds the mainchain fee into its
    /// reported `value` — so it could not be reconstructed into an exact `Content` even if we tried.
    /// Both reasons point the same way: never hand one to coin selection.
    @Test func withdrawalRowIsNotSpendable() throws {
        let row = try Self.utxo(Self.valueUTXO(value: 1300, contentType: "withdrawal"))
        let address = try #require(ThunderAddress(base58: Self.address))
        #expect(row.pointedOutput(address: address) == nil)
        // …but it still parses as an outpoint, so history can account for it.
        #expect(row.outPoint() != nil)
    }

    @Test func malformedRowsAreDroppedRatherThanGuessed() throws {
        let address = try #require(ThunderAddress(base58: Self.address))

        // A hash that isn't 32 bytes can't be a Borsh outpoint.
        let shortHash = try Self.utxo(Self.valueUTXO(txid: "abcd"))
        #expect(shortHash.pointedOutput(address: address) == nil)

        // An unknown outpoint kind has no Borsh tag we could pick.
        let unknownKind = try Self.utxo(Self.valueUTXO(kind: "something_new"))
        #expect(unknownKind.pointedOutput(address: address) == nil)

        // A negative value would wrap to an enormous UInt64.
        let negative = try Self.utxo(Self.valueUTXO(value: -1))
        #expect(negative.pointedOutput(address: address) == nil)
    }

    // MARK: - The cross-backend invariant

    /// The same coin, described by the node RPC and by the index, must hash to the same utreexo leaf.
    ///
    /// This is what makes swapping backends safe: signing, Borsh encoding and the submitted JSON are
    /// shared code, so as long as both wire layers reconstruct an identical `PointedOutput`, which one
    /// is in use cannot change what the node validates.
    @Test func esploraAndRPCAgreeOnTheUtxoHash() throws {
        let rpcJSON = """
        [{"outpoint":{"Regular":{"txid":"\(Self.txidHex)","vout":2}},
          "output":{"address":"\(Self.address)","content":{"Value":12345}}}]
        """
        let viaRPC = try #require(
            try JSONDecoder().decode([ThunderRPCPointedOutput].self, from: Data(rpcJSON.utf8)).first?.spendable)

        let address = try #require(ThunderAddress(base58: Self.address))
        let viaEsplora = try #require(try Self.utxo(Self.valueUTXO()).pointedOutput(address: address))

        #expect(viaRPC == viaEsplora)
        #expect(viaRPC.utxoHash() == viaEsplora.utxoHash())
        #expect(viaRPC.borshEncoded() == viaEsplora.borshEncoded())
    }

    /// Same again for a deposit, where the two wire layers disagree about byte order on the way in and
    /// must still land on the same internal bytes. This is the variant most likely to be got wrong.
    @Test func esploraAndRPCAgreeOnADepositUtxoHash() throws {
        var displayOrder = [UInt8](repeating: 0x07, count: 32)
        displayOrder[0] = 0xfe
        let hex = displayOrder.map { String(format: "%02x", $0) }.joined()

        // The node serializes a Deposit outpoint as bitcoin::OutPoint's Display: "txid:vout".
        let rpcJSON = """
        [{"outpoint":{"Deposit":"\(hex):2"},
          "output":{"address":"\(Self.address)","content":{"Value":12345}}}]
        """
        let viaRPC = try #require(
            try JSONDecoder().decode([ThunderRPCPointedOutput].self, from: Data(rpcJSON.utf8)).first?.spendable)

        let address = try #require(ThunderAddress(base58: Self.address))
        let viaEsplora = try #require(
            try Self.utxo(Self.valueUTXO(txid: hex, kind: "deposit")).pointedOutput(address: address))

        #expect(viaRPC.outPoint == viaEsplora.outPoint)
        #expect(viaRPC.utxoHash() == viaEsplora.utxoHash())
    }

    // MARK: - Status

    @Test func confirmationsCountFromTheTip() throws {
        let status = ThunderEsploraStatus(confirmed: true, blockHeight: 100,
                                          blockHash: nil, blockTime: nil)
        #expect(status.confirmations(tipHeight: 100) == 1)    // in the tip block = 1 deep
        #expect(status.confirmations(tipHeight: 105) == 6)
        // Tip and row come from two requests, so the index can be a block ahead of the tip we read.
        // Reporting a negative depth would be worse than reporting none.
        #expect(status.confirmations(tipHeight: 99) == 0)

        let unconfirmed = ThunderEsploraStatus(confirmed: false, blockHeight: nil,
                                               blockHash: nil, blockTime: nil)
        #expect(unconfirmed.confirmations(tipHeight: 100) == 0)
    }

    // MARK: - Address stats

    @Test func addressStatsDecideWhetherAnAddressIsWorthFetching() throws {
        let unused = """
        {"address":"\(Self.address)",
         "chain_stats":{"funded_txo_count":0,"funded_txo_sum":0,"spent_txo_count":0,
                        "spent_txo_sum":0,"tx_count":0},
         "mempool_stats":{"funded_txo_count":0,"funded_txo_sum":0,"spent_txo_count":0,
                          "spent_txo_sum":0,"tx_count":0}}
        """
        let info = try JSONDecoder().decode(ThunderEsploraAddressInfo.self, from: Data(unused.utf8))
        #expect(!info.isUsed)
        #expect(info.chainStats.txCount == 0)

        let used = """
        {"address":"\(Self.address)",
         "chain_stats":{"funded_txo_count":1,"funded_txo_sum":9000,"spent_txo_count":0,
                        "spent_txo_sum":0,"tx_count":3},
         "mempool_stats":{"funded_txo_count":0,"funded_txo_sum":0,"spent_txo_count":0,
                          "spent_txo_sum":0,"tx_count":0}}
        """
        let usedInfo = try JSONDecoder().decode(ThunderEsploraAddressInfo.self, from: Data(used.utf8))
        #expect(usedInfo.isUsed)
        #expect(usedInfo.chainStats.txCount == 3)
    }

    /// An address that received and fully spent everything has `tx_count > 0` but no UTXOs. It still
    /// has to count as used — its history belongs in the list, and a wallet that treated it as fresh
    /// would stop extending the gap-limit window right where the coins were.
    @Test func aFullySpentAddressStillCountsAsUsed() throws {
        let json = """
        {"address":"\(Self.address)",
         "chain_stats":{"funded_txo_count":2,"funded_txo_sum":5000,"spent_txo_count":2,
                        "spent_txo_sum":5000,"tx_count":4},
         "mempool_stats":{"funded_txo_count":0,"funded_txo_sum":0,"spent_txo_count":0,
                          "spent_txo_sum":0,"tx_count":0}}
        """
        let info = try JSONDecoder().decode(ThunderEsploraAddressInfo.self, from: Data(json.utf8))
        #expect(info.isUsed)
    }
}
