// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Android/Linux Foundation (same as Pricing)
#endif

/// A minimal JSON-RPC 2.0 client for a Thunder node (`jsonrpsee` server, positional params).
///
/// Only the three methods the thin-node flow needs (docs/thunder-sidechain-support.md §8b): the phone
/// derives addresses, asks for their UTXOs, selects coins + builds + signs locally, and submits. The
/// node holds no seed and does no coin selection.
///
/// The network call is injected (`fetch`) so every method is unit-testable against canned JSON with no
/// server, and the seam returns `(Data, status)` rather than `URLResponse` to stay `Sendable` under
/// Swift 6 — the same shape `ConnectRPCClient` and the price providers use.
struct ThunderRPCClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    let endpoint: String
    private let fetch: Fetch

    init(endpoint: String, fetch: @escaping Fetch = ThunderRPCClient.defaultFetch) {
        self.endpoint = endpoint
        self.fetch = fetch
    }

    static func defaultFetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Methods

    /// `get_utxos(addresses) -> [PointedOutput]`, reading the node's **full chain UTXO state** (not its
    /// local wallet), so no seed ever leaves the phone. Shipped in thunder-rust commit ed23b82.
    func getUtxos(addresses: [String]) async throws -> [ThunderRPCPointedOutput] {
        try await call(method: "get_utxos", params: [addresses])
    }

    /// `get_stxos(addresses) -> [Pointed<SpentOutput>]` — outputs of ours that have been SPENT.
    /// The counterpart to `get_utxos`: together they cover every coin that ever touched these
    /// addresses, which is what history is reconstructed from (spends are invisible in the UTXO set).
    func getStxos(addresses: [String]) async throws -> [ThunderRPCPointedSpentOutput] {
        try await call(method: "get_stxos", params: [addresses])
    }

    /// `submit_transaction(Authorized<Transaction>) -> Txid`. The node regenerates the utreexo proof
    /// before validating (commit fb922ee), so we submit with an empty proof. Returns the txid hex.
    func submitTransaction(_ authorized: AuthorizedThunderTransaction) async throws -> String {
        try await call(method: "submit_transaction", params: [ThunderRPCAuthorizedTransaction(authorized: authorized)])
    }

    /// `getblockcount() -> u32` — the sidechain tip height. Used as a liveness/height probe.
    func blockCount() async throws -> Int64 {
        try await call(method: "getblockcount", params: [Int]())
    }

    // MARK: - Envelope

    private struct RPCRequest<P: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id = 1        // one request per HTTP round-trip, so a constant id is unambiguous
        let method: String
        let params: P
    }

    private struct RPCResponse<R: Decodable>: Decodable {
        let result: R?
        let error: RPCErrorBody?
    }

    private struct RPCErrorBody: Decodable {
        let code: Int
        let message: String
    }

    private func call<P: Encodable, R: Decodable>(method: String, params: P) async throws -> R {
        guard let url = URL(string: endpoint) else { throw ThunderRPCError.badURL(endpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(RPCRequest(method: method, params: params))
        } catch {
            throw ThunderRPCError.malformedResponse("encode \(method) request")
        }

        let data: Data
        let status: Int
        do {
            (data, status) = try await fetch(request)
        } catch {
            throw ThunderRPCError.network
        }

        // jsonrpsee reports application errors in the body with HTTP 200; a non-2xx is transport-level.
        let decoded: RPCResponse<R>
        do {
            decoded = try JSONDecoder().decode(RPCResponse<R>.self, from: data)
        } catch {
            guard (200..<300).contains(status) else {
                throw ThunderRPCError.server(code: status, message: "HTTP \(status)")
            }
            throw ThunderRPCError.malformedResponse("decode \(method) result")
        }
        if let error = decoded.error { throw ThunderRPCError.server(code: error.code, message: error.message) }
        guard let result = decoded.result else { throw ThunderRPCError.malformedResponse("\(method): no result") }
        return result
    }
}
