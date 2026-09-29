// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A BIP300 enforcer's read API (`cusf.mainchain.v1.ValidatorService`), called as ConnectRPC unary
/// over HTTPS + JSON through the same `ConnectRPCClient` transport as CoinNews and the faucet.
///
/// The hosted enforcer puts a read-only allowlist in front of these methods; wallet methods answer
/// 403. No auth. Verified live against betanet 2026-09-29; the payloads in
/// `EnforcerClientTests` are captured from it. Design and trust model: `docs/sidechain-deposits.md` §3a′.
///
/// Wire notes (proto3 JSON):
/// - `uint64` arrives as a JSON **string** (`"value":"519790000"`); `uint32` as a number.
/// - Zero values are **omitted**: a CTIP at `vout` 0 has no `vout` key, and a slot with no treasury
///   answers `{}`.
/// - Request field names follow the proto: `GetCtip` takes `sidechainNumber`, while the bundle
///   request takes `sidechainId`. The enforcer rejects a request with the wrong one.
struct EnforcerClient: EnforcerFetching {
    private static let service = "cusf.mainchain.v1.ValidatorService"
    private let rpc: ConnectRPCClient

    init(endpoint: URL, fetch: @escaping ConnectRPCClient.Fetch = ConnectRPCClient.defaultFetch) {
        self.rpc = ConnectRPCClient(baseURL: endpoint, fetch: fetch)
    }

    func chainTip() async throws -> EnforcerChainTip {
        let res: ChainTipResponse = try await call("GetChainTip", EmptyRequest())
        guard let info = res.blockHeaderInfo, let hash = info.blockHash?.hex, !hash.isEmpty else {
            throw EnforcerError.malformed("chain tip has no block hash")
        }
        // Height 0 is omitted by proto3, and genesis is the only block where that's true.
        return EnforcerChainTip(height: info.height ?? 0, blockHash: hash)
    }

    func bip300Constants() async throws -> Bip300Constants {
        let res: ChainInfoResponse = try await call("GetChainInfo", EmptyRequest())
        guard let c = res.bip300Constants else { throw EnforcerError.malformed("chain info has no BIP300 constants") }
        return Bip300Constants(
            withdrawalBundleMaxAge: c.withdrawalBundleMaxAge ?? 0,
            withdrawalBundleInclusionThreshold: c.withdrawalBundleInclusionThreshold ?? 0,
            usedSlotActivationThreshold: c.usedSidechainSlotActivationThreshold ?? 0,
            unusedSlotActivationThreshold: c.unusedSidechainSlotActivationThreshold ?? 0,
            activationHeight: c.activationHeight ?? 0)
    }

    func sidechains() async throws -> [Sidechain] {
        let res: SidechainsResponse = try await call("GetSidechains", EmptyRequest())
        return (res.sidechains ?? [])
            .compactMap { wire -> Sidechain? in
                // Slot 0 is a real slot, and proto3 omits it, so absent means 0. Out-of-range means a
                // broken answer; drop it rather than offer a deposit to a slot that can't exist.
                let slot = wire.sidechainNumber ?? 0
                guard Self.isValidSlot(slot) else { return nil }
                let v0 = wire.declaration?.v0
                return Sidechain(
                    slot: slot,
                    title: Self.title(v0?.title, slot: slot),
                    description: v0?.description ?? "",
                    voteCount: wire.voteCount ?? 0,
                    proposalHeight: wire.proposalHeight ?? 0,
                    activationHeight: wire.activationHeight ?? 0)
            }
            .sorted { $0.slot < $1.slot }
    }

    func treasury(slot: Int) async throws -> SidechainTreasury? {
        guard Self.isValidSlot(slot) else { throw EnforcerError.invalidSlot(slot) }
        let res: CtipResponse = try await call("GetCtip", SidechainNumberRequest(sidechainNumber: slot))
        guard let ctip = res.ctip else { return nil }   // `{}`: no deposits to this slot yet
        guard let txid = ctip.txid?.hex, Self.isTxid(txid) else {
            throw EnforcerError.malformed("treasury has no valid txid")
        }
        // `value` is uint64 → string, and proto3 omits it at zero, so absent means 0. A treasury
        // that withdrawals have drained really can hold 0. Present but unparseable is a broken
        // answer: building a deposit on a guessed value would make the new treasury output wrong,
        // so refuse.
        let value: Int64
        if let raw = ctip.value {
            guard let parsed = Int64(raw), parsed >= 0 else { throw EnforcerError.malformed("treasury value \(raw)") }
            value = parsed
        } else {
            value = 0
        }
        return SidechainTreasury(
            txid: txid.lowercased(),
            vout: ctip.vout ?? 0,
            valueSats: value,
            sequenceNumber: ctip.sequenceNumber.flatMap { Int64($0) } ?? 0)
    }

    func sidechainProposals() async throws -> [SidechainProposal] {
        let res: ProposalsResponse = try await call("GetSidechainProposals", EmptyRequest())
        return (res.sidechainProposals ?? [])
            .compactMap { wire -> SidechainProposal? in
                let slot = wire.sidechainNumber ?? 0
                guard Self.isValidSlot(slot) else { return nil }
                let v0 = wire.declaration?.v0
                return SidechainProposal(
                    slot: slot,
                    title: Self.title(v0?.title, slot: slot),
                    description: v0?.description ?? "",
                    voteCount: wire.voteCount ?? 0,
                    proposalHeight: wire.proposalHeight ?? 0,
                    proposalAge: wire.proposalAge ?? 0)
            }
            .sorted { $0.slot < $1.slot }
    }

    func withdrawalBundleProposals(slot: Int) async throws -> [WithdrawalBundleProposal] {
        guard Self.isValidSlot(slot) else { throw EnforcerError.invalidSlot(slot) }
        let res: BundleProposalsResponse = try await call(
            "GetWithdrawalBundleProposals", SidechainIdRequest(sidechainId: slot))
        return (res.proposals ?? []).compactMap { wire in
            guard let m6id = wire.m6id?.hex, !m6id.isEmpty else { return nil }
            return WithdrawalBundleProposal(
                m6id: m6id, voteCount: wire.voteCount ?? 0, proposalHeight: wire.proposalHeight ?? 0)
        }
    }

    // MARK: - Helpers

    private func call<Req: Encodable, Res: Decodable>(_ method: String, _ request: Req) async throws -> Res {
        do {
            return try await rpc.unary(service: Self.service, method: method, request: request)
        } catch let error as CoinNewsError {
            throw EnforcerError.from(error)
        }
    }

    static func isValidSlot(_ slot: Int) -> Bool { (0...255).contains(slot) }

    /// 32 bytes of hex. The txid feeds a transaction input later, so it's checked here, once.
    static func isTxid(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy(\.isHexDigit)
    }

    /// A sidechain whose description isn't a v0 declaration has no title. That's legal, and the slot
    /// is still real, so name it by slot rather than drop it.
    private static func title(_ raw: String?, slot: Int) -> String {
        if let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return "Slot \(slot)"
    }
}

// MARK: - cusf.mainchain.v1 wire shapes (proto3 JSON; every field optional because proto3 omits defaults)

private struct SidechainNumberRequest: Encodable { let sidechainNumber: Int }
private struct SidechainIdRequest: Encodable { let sidechainId: Int }

/// `cusf.common.v1.{ConsensusHex,ReverseHex}`: `{"hex": "…"}`.
private struct WireHex: Decodable { let hex: String? }

private struct ChainTipResponse: Decodable {
    struct HeaderInfo: Decodable {
        let blockHash: WireHex?
        let height: Int?
    }
    let blockHeaderInfo: HeaderInfo?
}

private struct ChainInfoResponse: Decodable {
    struct Constants: Decodable {
        let withdrawalBundleMaxAge: Int?
        let withdrawalBundleInclusionThreshold: Int?
        let usedSidechainSlotActivationThreshold: Int?
        let unusedSidechainSlotActivationThreshold: Int?
        let activationHeight: Int?
    }
    let bip300Constants: Constants?
}

private struct WireDeclaration: Decodable {
    struct V0: Decodable {
        let title: String?
        let description: String?
    }
    let v0: V0?
}

private struct SidechainsResponse: Decodable {
    struct Info: Decodable {
        let sidechainNumber: Int?
        let voteCount: Int?
        let proposalHeight: Int?
        let activationHeight: Int?
        let declaration: WireDeclaration?
    }
    let sidechains: [Info]?
}

private struct CtipResponse: Decodable {
    struct Ctip: Decodable {
        let txid: WireHex?
        let vout: Int?
        let value: String?            // uint64 → JSON string
        let sequenceNumber: String?   // uint64 → JSON string
    }
    let ctip: Ctip?
}

private struct ProposalsResponse: Decodable {
    struct Proposal: Decodable {
        let sidechainNumber: Int?
        let declaration: WireDeclaration?
        let voteCount: Int?
        let proposalHeight: Int?
        let proposalAge: Int?
    }
    let sidechainProposals: [Proposal]?
}

private struct BundleProposalsResponse: Decodable {
    struct Proposal: Decodable {
        let m6id: WireHex?
        let voteCount: Int?
        let proposalHeight: Int?
    }
    let proposals: [Proposal]?
}
