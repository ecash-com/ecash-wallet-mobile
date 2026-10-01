// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// Withdrawal status tracking. Fixtures are a REAL betanet withdrawal (2026-10-01): Thunder tx
/// `8f2c66…be07` (block 588) has a withdrawal output at vout 0; the index reports it spent by
/// `withdrawal_bundle` with txid `d4ce…76aa`, which is the enforcer's batch `aa769f…ced4` byte-reversed.
@Suite struct WithdrawalStatusTests {
    private static let txid = "8f2c66ab092ebd44f49c391e8e37cc685b80b1b33273ac6b0086c4f384fcbe07"
    private static let outspendTxid = "d4ceb030ae2c52506c3b058d5904682319ba620d48dcb69fe5c7dd72ec9f76aa"
    private static let m6id = "aa769fec72ddc7e59fb6dc480d62ba19236804598d053b6c50522cae30b0ced4"

    private static let batched = ThunderEsploraOutspend(spent: true, txid: outspendTxid, spentBy: "withdrawal_bundle")
    private static let unspent = ThunderEsploraOutspend(spent: false, txid: nil, spentBy: nil)

    @Test func liveOutspendDecodesAndReversesToTheEnforcersM6id() throws {
        let json = #"{"spent":true,"txid":"\#(Self.outspendTxid)","vin":null,"status":{"confirmed":true,"block_height":642,"block_hash":"6ae4ad5a7bce16aec1743b3181cad4d927ca4a330c899b808baec34a0bf91ac4","block_time":null},"spent_by":"withdrawal_bundle"}"#
        let outspend = try JSONDecoder().decode(ThunderEsploraOutspend.self, from: Data(json.utf8))
        #expect(outspend.withdrawalBundleM6id == Self.m6id)
        let unspent = try JSONDecoder().decode(ThunderEsploraOutspend.self,
                                               from: Data(#"{"spent":false,"txid":null,"vin":null,"status":null}"#.utf8))
        #expect(unspent.withdrawalBundleM6id == nil)
    }

    @Test func aNonBundleSpendIsNotABatch() {
        let regular = ThunderEsploraOutspend(spent: true, txid: Self.outspendTxid, spentBy: "transaction")
        #expect(regular.withdrawalBundleM6id == nil)
    }

    private func resolve(confirmed: Bool = true, _ outspend: ThunderEsploraOutspend,
                         proposals: [WithdrawalBundleProposal], tip: Int? = 970_729) -> WithdrawalStatus {
        WithdrawalStatus.resolve(transactionConfirmed: confirmed, outspend: outspend, proposals: proposals,
                                 inclusionThreshold: 13_150, maxAge: 26_300, mainchainTipHeight: tip)
    }

    @Test func unconfirmedIsConfirming() {
        #expect(resolve(confirmed: false, Self.unspent, proposals: []) == .confirming)
    }

    @Test func unspentIsWaitingForABatch() {
        #expect(resolve(Self.unspent, proposals: []) == .waitingForBatch)
    }

    /// The live numbers: 136 votes at tip 970,729 for a batch proposed at 970,438.
    @Test func inAListedBatchIsVotingWithRealNumbers() {
        let status = resolve(Self.batched, proposals: [
            WithdrawalBundleProposal(m6id: Self.m6id, voteCount: 136, proposalHeight: 970_438),
        ])
        #expect(status == .voting(m6id: Self.m6id, votes: 136, votesNeeded: 13_151,
                                  blocksUntilExpiry: 26_300 - (970_729 - 970_438)))
        #expect(status.canStillPass)                       // 13,015 votes to go, 26,009 blocks left
        #expect(abs((status.voteFraction ?? 0) - 136.0 / 13_151.0) < 1e-9)
    }

    @Test func aBatchThatCanNoLongerPassIsFlagged() {
        // 5,000 votes, 1,000 blocks left: even a vote in every block can't reach 13,151.
        let status = resolve(Self.batched, proposals: [
            WithdrawalBundleProposal(m6id: Self.m6id, voteCount: 5_000, proposalHeight: 970_729 - 25_300),
        ])
        #expect(!status.canStillPass)
    }

    @Test func spentByABatchTheEnforcerNoLongerListsIsPaid() {
        #expect(resolve(Self.batched, proposals: []) == .paid(m6id: Self.m6id))
    }

    @Test func enforcerHexIsMatchedCaseInsensitively() {
        let status = resolve(Self.batched, proposals: [
            WithdrawalBundleProposal(m6id: Self.m6id.uppercased(), voteCount: 1, proposalHeight: 970_700),
        ])
        guard case .voting = status else { Issue.record("expected voting, got \(status)"); return }
    }

    // MARK: - Tracker, end to end over stubbed index + enforcer

    private func tracker(txConfirmed: Bool = true, outspendJSON: String,
                         enforcer: SidechainsViewModelTests.MockEnforcer = .init()) -> ThunderWithdrawalTracker {
        let status = txConfirmed
            ? #"{"confirmed":true,"block_height":588,"block_hash":"aa","block_time":null}"#
            : #"{"confirmed":false,"block_height":null,"block_hash":null,"block_time":null}"#
        let txJSON = #"{"txid":"\#(Self.txid)","fee":200,"size":100,"vin":[],"vout":[{"scriptpubkey_address":"4Y5BPeRQVg3jdU6oszDWZMbrV7jq","value":99000,"content_type":"withdrawal","content":{"Withdrawal":{"value":89000,"main_fee":10000,"main_address":"bc1qaw84063ptkynlelkj4l6jff2erhnru93kcdg96"}}}],"status":\#(status)}"#
        let index = ThunderEsploraClient(endpoint: "https://index.example/thunder") { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/outspend/0") { return (Data(outspendJSON.utf8), 200) }
            if path.hasSuffix("/tx/\(Self.txid)") { return (Data(txJSON.utf8), 200) }
            return (Data("not found".utf8), 404)
        }
        return ThunderWithdrawalTracker(index: index, enforcer: enforcer, slot: 9)
    }

    @Test func trackerReportsVotingFromTheEnforcer() async throws {
        let enforcer = SidechainsViewModelTests.MockEnforcer()
        enforcer.bundles[9] = [WithdrawalBundleProposal(m6id: Self.m6id, voteCount: 156, proposalHeight: 970_438)]
        let json = #"{"spent":true,"txid":"\#(Self.outspendTxid)","spent_by":"withdrawal_bundle"}"#
        let status = try await tracker(outspendJSON: json, enforcer: enforcer).status(txid: Self.txid)
        guard case let .voting(m6id, votes, needed, _) = status else { Issue.record("got \(status)"); return }
        #expect(m6id == Self.m6id && votes == 156 && needed == 13_151)
    }

    @Test func trackerReportsWaitingAndConfirming() async throws {
        let unspentJSON = #"{"spent":false,"txid":null,"vin":null,"status":null}"#
        #expect(try await tracker(outspendJSON: unspentJSON).status(txid: Self.txid) == .waitingForBatch)
        #expect(try await tracker(txConfirmed: false, outspendJSON: unspentJSON).status(txid: Self.txid) == .confirming)
    }
}
