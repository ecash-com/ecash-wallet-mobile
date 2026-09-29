// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// `EnforcerClient` decode/map. The payloads are real betanet answers captured 2026-09-29 from
/// `seed.beta.ecash.eu.com/enforcer` (trimmed to the fields we read, plus the ones we deliberately
/// ignore, so an ignored field can't break decoding). No network.
@Suite struct EnforcerClientTests {

    private static let endpoint = URL(string: "https://enforcer.test/enforcer")!

    /// Records every request so tests can check the method path and request body.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { _requests } }
        func record(_ r: URLRequest) { lock.withLock { _requests.append(r) } }
    }

    private func client(_ json: String, status: Int = 200, recorder: Recorder? = nil) -> EnforcerClient {
        let data = Data(json.utf8)
        return EnforcerClient(endpoint: Self.endpoint) { request in
            recorder?.record(request)
            return (data, status)
        }
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        guard let data = request?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    // MARK: - GetSidechains

    @Test func sidechainsDecodeFromLivePayload() async throws {
        let json = """
        {"sidechains":[\
        {"sidechainNumber":9,"description":{"hex":"7c00"},"voteCount":1009,"proposalHeight":967989,"activationHeight":968998,\
         "declaration":{"v0":{"title":"Thunder","description":"A sidechain with a large & growing blocksize, plus fraud proofs",\
         "hashId1":{"hex":"c46e"},"hashId2":{"hex":"2559"}}}},\
        {"sidechainNumber":2,"description":{"hex":"7500"},"voteCount":1009,"proposalHeight":967989,"activationHeight":968998,\
         "declaration":{"v0":{"title":"BitNames","description":"A variant of Namecoin/BitDNS that aims to replace ICANN"}}}\
        ]}
        """
        let recorder = Recorder()
        let sidechains = try await client(json, recorder: recorder).sidechains()

        #expect(sidechains.map(\.slot) == [2, 9])   // sorted by slot, not wire order
        #expect(sidechains[1].title == "Thunder")
        #expect(sidechains[1].description == "A sidechain with a large & growing blocksize, plus fraud proofs")
        #expect(sidechains[1].voteCount == 1009)
        #expect(sidechains[1].activationHeight == 968_998)
        #expect(recorder.requests.first?.url?.absoluteString
                == "https://enforcer.test/enforcer/cusf.mainchain.v1.ValidatorService/GetSidechains")
        #expect(recorder.requests.first?.httpMethod == "POST")
    }

    @Test func sidechainAtSlotZeroSurvivesProto3Omission() async throws {
        // proto3 omits `sidechainNumber` when it's 0. Slot 0 is real; it must not be dropped or renumbered.
        let json = #"{"sidechains":[{"voteCount":5,"declaration":{"v0":{"title":"Zero"}}}]}"#
        let sidechains = try await client(json).sidechains()
        #expect(sidechains.count == 1)
        #expect(sidechains[0].slot == 0)
        #expect(sidechains[0].title == "Zero")
    }

    @Test func sidechainWithoutDeclarationIsNamedBySlot() async throws {
        // A non-v0 description is legal; the enforcer then reports no declaration. The slot is still active.
        let json = #"{"sidechains":[{"sidechainNumber":130,"voteCount":1009}]}"#
        let sidechains = try await client(json).sidechains()
        #expect(sidechains.first?.title == "Slot 130")
        #expect(sidechains.first?.description == "")
    }

    @Test func outOfRangeSlotIsDropped() async throws {
        let json = #"{"sidechains":[{"sidechainNumber":256,"declaration":{"v0":{"title":"Bogus"}}},{"sidechainNumber":9}]}"#
        let sidechains = try await client(json).sidechains()
        #expect(sidechains.map(\.slot) == [9])
    }

    @Test func noSidechainsIsEmpty() async throws {
        #expect(try await client("{}").sidechains().isEmpty)
    }

    // MARK: - GetCtip

    @Test func treasuryDecodesFromLivePayload() async throws {
        // Live betanet Thunder CTIP. `vout` is omitted because it is 0; uint64s arrive as strings.
        let json = """
        {"ctip":{"txid":{"hex":"f83c5c7a975798aefa35a98299b31bebcf4dda5edf885bd6f893244a1b2688c5"},\
        "value":"519790000","sequenceNumber":"8"}}
        """
        let recorder = Recorder()
        let treasury = try #require(try await client(json, recorder: recorder).treasury(slot: 9))

        #expect(treasury.txid == "f83c5c7a975798aefa35a98299b31bebcf4dda5edf885bd6f893244a1b2688c5")
        #expect(treasury.vout == 0)
        #expect(treasury.valueSats == 519_790_000)
        #expect(treasury.sequenceNumber == 8)
        #expect(recorder.requests.first?.url?.lastPathComponent == "GetCtip")
        // GetCtip's field is `sidechainNumber`; the enforcer rejects anything else (checked live).
        #expect(body(recorder.requests.first)["sidechainNumber"] as? Int == 9)
    }

    @Test func slotWithNoDepositsHasNoTreasury() async throws {
        // Live answer for betanet slot 98 (zSide): active, never deposited to.
        #expect(try await client("{}").treasury(slot: 98) == nil)
    }

    @Test func treasuryAtNonZeroVout() async throws {
        let json = #"{"ctip":{"txid":{"hex":"\#(String(repeating: "ab", count: 32))"},"vout":2,"value":"1000","sequenceNumber":"3"}}"#
        #expect(try await client(json).treasury(slot: 4)?.vout == 2)
    }

    @Test func drainedTreasuryIsZeroNotError() async throws {
        // proto3 omits a zero `value`. A treasury emptied by withdrawals is legitimately 0.
        let json = #"{"ctip":{"txid":{"hex":"\#(String(repeating: "cd", count: 32))"},"sequenceNumber":"12"}}"#
        #expect(try await client(json).treasury(slot: 9)?.valueSats == 0)
    }

    @Test func treasuryWithBadTxidIsRejected() async throws {
        // The txid becomes a transaction input later. A short or non-hex one must not get through.
        let json = #"{"ctip":{"txid":{"hex":"f83c5c7a"},"value":"100"}}"#
        await #expect(throws: EnforcerError.self) { try await client(json).treasury(slot: 9) }
    }

    @Test func treasuryWithUnparseableValueIsRejected() async throws {
        let json = #"{"ctip":{"txid":{"hex":"\#(String(repeating: "ef", count: 32))"},"value":"lots"}}"#
        await #expect(throws: EnforcerError.self) { try await client(json).treasury(slot: 9) }
    }

    @Test func invalidSlotNeverReachesTheWire() async throws {
        let recorder = Recorder()
        await #expect(throws: EnforcerError.invalidSlot(256)) {
            try await client("{}", recorder: recorder).treasury(slot: 256)
        }
        await #expect(throws: EnforcerError.invalidSlot(-1)) {
            try await client("{}", recorder: recorder).withdrawalBundleProposals(slot: -1)
        }
        #expect(recorder.requests.isEmpty)
    }

    // MARK: - GetChainTip / GetChainInfo

    @Test func chainTipDecodesFromLivePayload() async throws {
        let json = """
        {"blockHeaderInfo":{"blockHash":{"hex":"0000000000000000dd0fc95d387d129add2e7d913864891f825ffffcb28d1a22"},\
        "prevBlockHash":{"hex":"00000000000000003f6cd22f50db8f72021ab4b1eed009a957353b452f817bc1"},\
        "height":970659,"work":{"hex":"3ede"},"timestamp":"1790696431"}}
        """
        let tip = try await client(json).chainTip()
        #expect(tip.height == 970_659)
        #expect(tip.blockHash == "0000000000000000dd0fc95d387d129add2e7d913864891f825ffffcb28d1a22")
    }

    @Test func chainTipWithoutHashIsMalformed() async throws {
        await #expect(throws: EnforcerError.self) { try await client(#"{"blockHeaderInfo":{"height":5}}"#).chainTip() }
    }

    @Test func bip300ConstantsDecodeFromLivePayload() async throws {
        let json = """
        {"network":"NETWORK_MAINNET","bip300Constants":{"withdrawalBundleMaxAge":26300,\
        "withdrawalBundleInclusionThreshold":13150,"usedSidechainSlotProposalMaxAge":26300,\
        "usedSidechainSlotActivationThreshold":13150,"unusedSidechainSlotProposalMaxAge":2016,\
        "unusedSidechainSlotActivationThreshold":1008,"activationHeight":967680}}
        """
        let c = try await client(json).bip300Constants()
        #expect(c.withdrawalBundleMaxAge == 26_300)
        #expect(c.withdrawalBundleInclusionThreshold == 13_150)
        #expect(c.unusedSlotActivationThreshold == 1_008)
        #expect(c.activationHeight == 967_680)   // betanet's fork height
    }

    // MARK: - Proposals

    @Test func sidechainProposalsDecodeFromLivePayload() async throws {
        let json = """
        {"sidechainProposals":[\
        {"sidechainNumber":24,"description":{"hex":"f200"},"declaration":{"v0":{"title":"Elements","description":"Elements Drivechain v11"}},\
         "descriptionSha256dHash":{"hex":"866e"},"voteCount":953,"proposalHeight":969706,"proposalAge":953},\
        {"sidechainNumber":8,"description":{"hex":"4e00"},"declaration":{"v0":{"title":"Solana","description":"A Solana sidechain"}},\
         "descriptionSha256dHash":{"hex":"14f8"},"voteCount":808,"proposalHeight":969851,"proposalAge":808}\
        ]}
        """
        let proposals = try await client(json).sidechainProposals()
        #expect(proposals.map(\.slot) == [8, 24])
        #expect(proposals[0].title == "Solana")
        #expect(proposals[0].voteCount == 808)
        #expect(proposals[1].proposalAge == 953)
    }

    @Test func withdrawalBundlesDecodeFromLivePayload() async throws {
        let json = """
        {"proposals":[{"m6id":{"hex":"aa769fec72ddc7e59fb6dc480d62ba19236804598d053b6c50522cae30b0ced4"},\
        "voteCount":121,"proposalHeight":970438}]}
        """
        let recorder = Recorder()
        let bundles = try await client(json, recorder: recorder).withdrawalBundleProposals(slot: 9)
        #expect(bundles.count == 1)
        #expect(bundles[0].m6id == "aa769fec72ddc7e59fb6dc480d62ba19236804598d053b6c50522cae30b0ced4")
        #expect(bundles[0].voteCount == 121)
        // Unlike GetCtip, this request's field is `sidechainId` (per the proto). Checked live.
        #expect(body(recorder.requests.first)["sidechainId"] as? Int == 9)
        #expect(body(recorder.requests.first)["sidechainNumber"] == nil)
    }

    // MARK: - Errors

    @Test func connectErrorEnvelopeMapsToServer() async throws {
        // The live answer to GetCtip with no slot.
        let json = #"{"code":"invalid_argument","message":"Missing field in message `cusf.mainchain.v1.GetCtipRequest`: `sidechain_number`"}"#
        await #expect(throws: EnforcerError.server(
            status: 400,
            message: "Missing field in message `cusf.mainchain.v1.GetCtipRequest`: `sidechain_number`")) {
            try await client(json, status: 400).treasury(slot: 9)
        }
    }

    @Test func forbiddenMethodMapsToServer() async throws {
        // The hosted enforcer answers 403 (plain text) for anything outside its read-only allowlist.
        await #expect(throws: EnforcerError.server(status: 403, message: nil)) {
            try await client("remote enforcer method is unavailable", status: 403).sidechains()
        }
    }

    @Test func networkFailureMapsToNetwork() async throws {
        struct Offline: Error {}
        let offline = EnforcerClient(endpoint: Self.endpoint) { _ in throw Offline() }
        await #expect(throws: EnforcerError.network) { try await offline.chainTip() }
    }

    @Test func garbageMapsToMalformed() async throws {
        await #expect(throws: EnforcerError.self) { try await client("<!DOCTYPE html>").sidechains() }
    }

    // MARK: - LIVE (opt-in): the hosted betanet enforcer

    /// Run with `ENFORCER_LIVE=1` in the test environment. No-op otherwise.
    @Test func liveBetanetEnforcer() async throws {
        guard ProcessInfo.processInfo.environment["ENFORCER_LIVE"] == "1" else { return }
        let live = EnforcerClient(endpoint: try #require(EnforcerEndpointRegistry.endpoint(for: .ecashBeta)))

        let tip = try await live.chainTip()
        let constants = try await live.bip300Constants()
        let sidechains = try await live.sidechains()
        let thunder = try await live.treasury(slot: 9)
        let proposals = try await live.sidechainProposals()
        let bundles = try await live.withdrawalBundleProposals(slot: 9)

        #expect(tip.height > constants.activationHeight)
        #expect(constants.activationHeight == 967_680)   // betanet, not alphanet
        #expect(sidechains.contains { $0.slot == 9 && $0.title == "Thunder" })
        #expect(thunder != nil)
        print("ENFORCER LIVE: tip \(tip.height); \(sidechains.count) active: "
              + sidechains.map { "\($0.slot) \($0.title)" }.joined(separator: ", ")
              + "; Thunder treasury \(thunder?.valueSats ?? -1) sats @ \(thunder?.txid.prefix(8) ?? "-"):\(thunder?.vout ?? -1)"
              + "; \(proposals.count) proposals; \(bundles.count) Thunder bundles")
    }
}

/// Which networks get an enforcer, and the remote overlay. Serialized because it writes UserDefaults.
@Suite(.serialized) struct EnforcerEndpointRegistryTests {

    @Test func bundledDefaults() {
        RemoteServiceOverrides.clearAll()
        #expect(EnforcerEndpointRegistry.endpoint(for: .ecashBeta)?.absoluteString
                == "https://seed.beta.ecash.eu.com/enforcer")
        // Alphanet's host serves betanet's chain today, so it stays off (docs/sidechain-deposits.md §3a′).
        #expect(EnforcerEndpointRegistry.endpoint(for: .ecash) == nil)
        #expect(EnforcerEndpointRegistry.endpoint(for: .signet) == nil)
        #expect(EnforcerEndpointRegistry.endpoint(for: .bitcoin) == nil)
        #expect(EnforcerEndpointRegistry.endpoint(for: .thunder) == nil)
    }

    @Test func remoteOverlayWins() {
        RemoteServiceOverrides.clearAll()
        defer { RemoteServiceOverrides.clearAll() }
        RemoteServiceOverrides.setEnforcerURL("https://seed.alpha.example/enforcer", for: .ecash)
        #expect(EnforcerEndpointRegistry.endpoint(for: .ecash)?.absoluteString == "https://seed.alpha.example/enforcer")
        #expect(EnforcerEndpointRegistry.isAvailable(on: .ecash))
    }

    @Test func configResolvesEnforcerPerNetwork() throws {
        let json = """
        {"schema_version":1,"networks":[\
        {"id":"betanet","family":"ecash","backends":[],"services":{"enforcer":{"url":" https://seed.beta.ecash.eu.com/enforcer "}}},\
        {"id":"alphanet","family":"ecash","backends":[],"services":{"enforcer":{"url":null}}},\
        {"id":"signet","family":"bitcoin","backends":[],"services":{"coinnews":{"url":"https://c.example"}}}\
        ]}
        """
        let config = try #require(RemoteEndpointConfig.parse(Data(json.utf8)))
        let resolved = config.resolvedEnforcers()
        #expect(resolved == [.init(network: .ecashBeta, url: "https://seed.beta.ecash.eu.com/enforcer")])
    }
}
