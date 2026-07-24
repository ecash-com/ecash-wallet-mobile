// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// `WalletFacade` routing — the seam that sends `.thunder` wallets to the Fuse-native engine and
/// everything else to the bridged BDK path. Uses recording `WalletOps` on both sides so we can assert
/// exactly which engine each op landed on, with no real BDK/Thunder/network.
@MainActor
@Suite struct WalletFacadeTests {

    private final class RecordingOps: WalletOps {
        let tag: String
        private(set) var calls: [String] = []
        init(_ tag: String) { self.tag = tag }

        func balance(walletId: String) throws -> Amount { calls.append("balance:\(walletId)"); return Amount(sats: tag == "thunder" ? 2 : 1) }
        func pendingBalance(walletId: String) throws -> Amount { calls.append("pending:\(walletId)"); return Amount(sats: 0) }
        func sync(walletId: String) async throws -> Amount { calls.append("sync:\(walletId)"); return Amount(sats: 0) }
        func receiveAddress(walletId: String, unused: Bool) async throws -> AddressInfo {
            calls.append("recv:\(walletId):\(unused)"); return AddressInfo(address: tag, index: 0)
        }
        func transactions(walletId: String) throws -> [WalletTx] { calls.append("txs:\(walletId)"); return [] }
        func send(walletId: String, to address: String, amount: Amount, feeRate: FeeRate) async throws -> WalletTx {
            calls.append("send:\(walletId)")
            return WalletTx(txid: tag, netSats: 0, feeSats: nil, confirmations: 0, timestampEpochSeconds: nil, isRBF: false)
        }
        func sweep(walletId: String, to address: String, feeRate: FeeRate) async throws -> WalletTx {
            calls.append("sweep:\(walletId)")
            return WalletTx(txid: tag, netSats: 0, feeSats: nil, confirmations: 0, timestampEpochSeconds: nil, isRBF: false)
        }
        func splitToSelf(walletId: String, feeRate: FeeRate) async throws -> WalletTx {
            calls.append("split:\(walletId)")
            return WalletTx(txid: tag, netSats: 0, feeSats: nil, confirmations: 0, timestampEpochSeconds: nil, isRBF: false)
        }
        func splitSummary(walletId: String) throws -> SplitSummary {
            calls.append("summary:\(walletId)")
            return SplitSummary(spendableSats: 0, needsSplitSats: 0, needsSplitCount: 0)
        }
    }

    /// Facade with recording BDK + Thunder sides; only "thunder-id" routes to Thunder.
    private func makeFacade() -> (WalletFacade, primary: RecordingOps, thunder: RecordingOps) {
        let primary = RecordingOps("bdk")
        let thunder = RecordingOps("thunder")
        let facade = WalletFacade(primary: primary, thunder: thunder, isThunder: { $0 == "thunder-id" })
        return (facade, primary, thunder)
    }

    @Test func thunderWalletRoutesToThunderEngine() throws {
        let (facade, primary, thunder) = makeFacade()
        #expect(try facade.balance(walletId: "thunder-id") == Amount(sats: 2))   // the Thunder side's canned value
        #expect(thunder.calls == ["balance:thunder-id"])
        #expect(primary.calls.isEmpty)
    }

    @Test func otherWalletsRouteToBDK() async throws {
        let (facade, primary, thunder) = makeFacade()
        #expect(try facade.balance(walletId: "btc-id") == Amount(sats: 1))       // the primary side's canned value
        _ = try await facade.sync(walletId: "btc-id")
        #expect(primary.calls == ["balance:btc-id", "sync:btc-id"])
        #expect(thunder.calls.isEmpty)
    }

    @Test func everyOpHonorsTheRoute() async throws {
        let (facade, primary, thunder) = makeFacade()
        _ = try facade.balance(walletId: "thunder-id")
        _ = try facade.pendingBalance(walletId: "thunder-id")
        _ = try await facade.sync(walletId: "thunder-id")
        _ = try await facade.receiveAddress(walletId: "thunder-id", unused: true)
        _ = try await facade.receiveAddress(walletId: "thunder-id", unused: false)
        _ = try facade.transactions(walletId: "thunder-id")
        _ = try await facade.send(walletId: "thunder-id", to: "x", amount: Amount(sats: 1), feeRate: FeeRate(satPerVByte: 1))
        _ = try await facade.sweep(walletId: "thunder-id", to: "x", feeRate: FeeRate(satPerVByte: 1))
        _ = try await facade.splitToSelf(walletId: "thunder-id", feeRate: FeeRate(satPerVByte: 1))
        _ = try facade.splitSummary(walletId: "thunder-id")
        #expect(thunder.calls.count == 10)    // all ten ops routed to Thunder
        #expect(primary.calls.isEmpty)
    }

    @Test func routingIsPerWalletNotGlobal() async throws {
        let (facade, primary, thunder) = makeFacade()
        _ = try facade.balance(walletId: "thunder-id")
        _ = try facade.balance(walletId: "btc-id")
        #expect(thunder.calls == ["balance:thunder-id"])
        #expect(primary.calls == ["balance:btc-id"])
    }
}
