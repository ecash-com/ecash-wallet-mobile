// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// History built from indexed transactions.
///
/// The value of this path over `ThunderHistory` is that nothing is inferred: the fee, height, time and
/// both sides of the ledger are all read. These tests pin that — and pin the two places where reading
/// them still requires a judgement call (whose fee it is, and what a self-transfer means).
@Suite struct ThunderEsploraHistoryTests {

    private static let mine = "38VvRdmcQREr1UAcZma98WLFVpAp"
    private static let mineChange = "3AnotherOfOurAddressesXXXXXXX"
    private static let theirs = "3SomeoneElsesAddressXXXXXXXXX"
    private static let ours: Set<String> = [mine, mineChange]

    private static func status(height: Int64, time: Int64 = 1_750_000_000) -> ThunderEsploraStatus {
        ThunderEsploraStatus(confirmed: true, blockHeight: height,
                             blockHash: String(repeating: "ab", count: 32), blockTime: time)
    }

    private static func tx(_ txid: String, fee: Int64 = 200, size: Int64 = 300,
                           height: Int64 = 100, time: Int64 = 1_750_000_000,
                           vin: [ThunderEsploraVin] = [], vout: [ThunderEsploraVout] = []) -> ThunderEsploraTx {
        ThunderEsploraTx(txid: txid, fee: fee, size: size, vin: vin, vout: vout,
                         status: status(height: height, time: time))
    }

    private static func out(_ address: String, _ value: Int64) -> ThunderEsploraVout {
        ThunderEsploraVout(scriptPubKeyAddress: address, value: value)
    }

    private static func spend(_ address: String, _ value: Int64) -> ThunderEsploraVin {
        ThunderEsploraVin(prevout: out(address, value))
    }

    // MARK: - Direction and amounts

    @Test func aReceiveIsPositiveAndCarriesRealBlockData() {
        let txs = [Self.tx("aa", fee: 200, size: 300, height: 100, time: 1_750_000_000,
                           vin: [Self.spend(Self.theirs, 50_000)],
                           vout: [Self.out(Self.mine, 40_000), Self.out(Self.theirs, 9_800)])]
        let rows = ThunderEsploraHistory.build(txs: txs, ours: Self.ours, tipHeight: 104)

        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.netSats == 40_000)
        #expect(row.receivedSats == 40_000)
        // Every one of these is nil or a placeholder on the node-RPC path.
        #expect(row.blockHeight == 100)
        #expect(row.confirmations == 5)
        #expect(row.timestampEpochSeconds == 1_750_000_000)
        #expect(row.vsize == 300)
        // We funded none of it, so the fee wasn't ours to report.
        #expect(row.feeSats == nil)
    }

    @Test func aSendIsNegativeAndOwnsItsFee() {
        let txs = [Self.tx("bb", fee: 200,
                           vin: [Self.spend(Self.mine, 50_000)],
                           vout: [Self.out(Self.theirs, 30_000), Self.out(Self.mineChange, 19_800)])]
        let rows = ThunderEsploraHistory.build(txs: txs, ours: Self.ours, tipHeight: 100)

        let row = rows[0]
        // −50,000 spent + 19,800 change back = −30,200, which is the payment plus the fee.
        #expect(row.netSats == -30_200)
        #expect(row.receivedSats == 19_800)   // the change
        #expect(row.feeSats == 200)
    }

    /// A self-transfer (the shape a sweep or a split takes) nets out to just the fee, so `netSats`
    /// alone would render a whole-balance move as ≈0. `receivedSats` is what the UI shows instead —
    /// the same rule the BDK path already relies on.
    @Test func aSelfTransferNetsToTheFeeButReportsWhatMoved() {
        let txs = [Self.tx("cc", fee: 200,
                           vin: [Self.spend(Self.mine, 50_000)],
                           vout: [Self.out(Self.mineChange, 49_800)])]
        let rows = ThunderEsploraHistory.build(txs: txs, ours: Self.ours, tipHeight: 100)

        #expect(rows[0].netSats == -200)          // only the fee left the wallet
        #expect(rows[0].receivedSats == 49_800)   // …but this much actually moved
        #expect(rows[0].feeSats == 200)
    }

    @Test func aCoinbaseInputIsNotTreatedAsOurSpend() {
        // A coinbase vin has no prevout to attribute; counting it would invent an outflow.
        let coinbase = ThunderEsploraVin(prevout: nil, isCoinbase: true)
        let txs = [Self.tx("dd", vin: [coinbase], vout: [Self.out(Self.mine, 5_000)])]
        let rows = ThunderEsploraHistory.build(txs: txs, ours: Self.ours, tipHeight: 100)

        #expect(rows[0].netSats == 5_000)
        #expect(rows[0].feeSats == nil)
    }

    @Test func outputsToStrangersDontCountAsOurs() {
        let txs = [Self.tx("ee", vin: [Self.spend(Self.theirs, 10_000)],
                           vout: [Self.out(Self.theirs, 9_800)])]
        let rows = ThunderEsploraHistory.build(txs: txs, ours: Self.ours, tipHeight: 100)
        #expect(rows[0].netSats == 0)
        #expect(rows[0].receivedSats == 0)
    }

    // MARK: - Assembly

    /// The index is queried per address, so a transaction touching three of our addresses comes back
    /// three times. Without dedup the Activity list would repeat it and any total over the rows would
    /// triple-count.
    @Test func theSameTransactionFromSeveralAddressesAppearsOnce() {
        let one = Self.tx("ff", vin: [Self.spend(Self.mine, 10_000)],
                          vout: [Self.out(Self.mineChange, 9_800)])
        let rows = ThunderEsploraHistory.build(txs: [one, one, one], ours: Self.ours, tipHeight: 100)
        #expect(rows.count == 1)
    }

    @Test func rowsAreNewestFirstByHeightThenTime() {
        let txs = [
            Self.tx("old", height: 10, time: 1_000, vout: [Self.out(Self.mine, 1)]),
            Self.tx("new", height: 30, time: 3_000, vout: [Self.out(Self.mine, 1)]),
            Self.tx("mid", height: 20, time: 2_000, vout: [Self.out(Self.mine, 1)]),
        ]
        let rows = ThunderEsploraHistory.build(txs: txs, ours: Self.ours, tipHeight: 30)
        #expect(rows.map(\.txid) == ["new", "mid", "old"])
    }

    @Test func twoInOneBlockBreakTheTieOnTime() {
        let txs = [
            Self.tx("earlier", height: 20, time: 2_000, vout: [Self.out(Self.mine, 1)]),
            Self.tx("later", height: 20, time: 2_500, vout: [Self.out(Self.mine, 1)]),
        ]
        let rows = ThunderEsploraHistory.build(txs: txs, ours: Self.ours, tipHeight: 20)
        #expect(rows.map(\.txid) == ["later", "earlier"])
    }

    /// Thunder has no RBF and no CoinNews — both are Bitcoin/eCash concepts. Pinned so neither quietly
    /// acquires a value if the shared `WalletTx` grows.
    @Test func thunderRowsCarryNoRBFOrCoinNewsMarkers() {
        let rows = ThunderEsploraHistory.build(txs: [Self.tx("aa", vout: [Self.out(Self.mine, 1)])],
                                               ours: Self.ours, tipHeight: 100)
        #expect(!rows[0].isRBF)
        #expect(rows[0].coinNewsKind == nil)
    }
}
