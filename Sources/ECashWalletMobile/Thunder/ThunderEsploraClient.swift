// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Android/Linux Foundation (same as Pricing)
#endif

/// A REST client for **drivechain-esplora** (github.com/octobocto/drivechain-esplora) — an
/// Esplora-compatible index in front of a Thunder node.
///
/// **Why this exists alongside `ThunderRPCClient`.** The node keys its state database by outpoint
/// only, so `get_utxos(addresses)` iterates the whole UTXO table and filters in memory, and the node
/// can answer no height, no time and no fee for a transaction — which is why `ThunderHistory` has to
/// invent an ordering and pin every confirmation count at 1. The index answers all of it from Postgres.
/// The seed still never leaves the phone: this reads public address data, and building, signing and
/// coin selection stay local exactly as before.
///
/// **What it costs.** There is no batch-address route — Esplora has none and this is faithful to it —
/// so a sync is one request per address rather than one for the whole window. `ThunderEsploraBackend`
/// is where that's managed (cheap stats probe first, bounded concurrency); this type stays a thin,
/// per-route wrapper.
///
/// The network call is injected (`fetch`) so every route is unit-testable against canned JSON with no
/// server, and the seam returns `(Data, status)` rather than `URLResponse` to stay `Sendable` under
/// Swift 6 — the same shape `ThunderRPCClient` and the price providers use.
struct ThunderEsploraClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    /// The index's base URL, including any mount path (`https://host/thunder`). Trailing slashes are
    /// stripped: the server mounts its routes at the base, and `…/thunder/` + `blocks/tip/height`
    /// would produce a double slash, which it answers with a 404.
    let endpoint: String
    private let fetch: Fetch

    init(endpoint: String, fetch: @escaping Fetch = ThunderEsploraClient.defaultFetch) {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.endpoint = trimmed
        self.fetch = fetch
    }

    static func defaultFetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Reads

    /// `GET /blocks/tip/height` — the indexed tip, as plain text.
    ///
    /// An index that has walked no blocks answers **404** here (`"the index holds no blocks yet"`)
    /// rather than 0, so that case maps to `.indexEmpty`: the endpoint is fine, it just has nothing to
    /// say yet, and the user should not be told their connection is broken.
    func tipHeight() async throws -> Int64 {
        let (data, status) = try await send(request(path: "/blocks/tip/height"))
        if status == 404 { throw ThunderBackendError.indexEmpty }
        try check(status: status, data: data, route: "blocks/tip/height")
        guard let text = plainText(data), let height = Int64(text) else {
            throw ThunderBackendError.malformedResponse("blocks/tip/height")
        }
        return height
    }

    /// `GET /address/{a}` — funded/spent counts. The cheap probe that decides whether an address is
    /// worth two more requests (see `ThunderEsploraBackend`).
    func addressInfo(_ address: String) async throws -> ThunderEsploraAddressInfo {
        try await decode(path: "/address/\(escape(address))", route: "address")
    }

    /// `GET /address/{a}/utxo` — this address's unspent outputs. The rows carry no address (the route
    /// is the key), so the caller pairs them back up; see `ThunderEsploraUTXO.pointedOutput(address:)`.
    func addressUTXOs(_ address: String) async throws -> [ThunderEsploraUTXO] {
        try await decode(path: "/address/\(escape(address))/utxo", route: "address utxo")
    }

    /// `GET /address/{a}/txs/chain[/{last_seen}]` — one page of confirmed history, newest first.
    ///
    /// A page holds 25 rows; a caller pages by passing the **last** txid it saw and stops on a short
    /// page. There is no mempool page to fetch — these nodes serve no mempool view at all.
    func addressTxs(_ address: String, lastSeen: String? = nil) async throws -> [ThunderEsploraTx] {
        var path = "/address/\(escape(address))/txs/chain"
        if let lastSeen, !lastSeen.isEmpty { path += "/\(escape(lastSeen))" }
        return try await decode(path: path, route: "address txs")
    }

    // MARK: - Write

    /// `POST /tx` — submit a signed transaction. Returns the txid as plain text.
    ///
    /// The body is the **same JSON object** `ThunderRPCClient.submitTransaction` sends as `params[0]`:
    /// the index relays it into the node's `submit_transaction` unchanged, signing nothing and
    /// rewriting nothing. So the entire authorization/Borsh path is shared between the two backends,
    /// and switching wire layers can't change what gets signed.
    func broadcast(_ authorized: AuthorizedThunderTransaction) async throws -> String {
        var req = request(path: "/tx")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONEncoder().encode(ThunderRPCAuthorizedTransaction(authorized: authorized))
        } catch {
            throw ThunderBackendError.malformedResponse("encode transaction")
        }
        let (data, status) = try await send(req)
        try check(status: status, data: data, route: "tx")
        guard let txid = plainText(data), !txid.isEmpty else {
            throw ThunderBackendError.malformedResponse("tx: no txid")
        }
        return txid
    }

    // MARK: - Plumbing

    private func request(path: String) -> URLRequest {
        // Built even when the URL is bad so `send` can report `.badURL` with the endpoint (which is
        // public config, never key material) rather than trapping.
        guard let url = URL(string: endpoint + path) else {
            return URLRequest(url: URL(string: "about:blank")!)
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url, url.scheme == "http" || url.scheme == "https" else {
            throw ThunderBackendError.badURL(endpoint)
        }
        do {
            return try await fetch(request)
        } catch {
            throw ThunderBackendError.network
        }
    }

    private func decode<T: Decodable>(path: String, route: String) async throws -> T {
        let (data, status) = try await send(request(path: path))
        try check(status: status, data: data, route: route)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ThunderBackendError.malformedResponse("decode \(route)")
        }
    }

    /// Non-2xx becomes `.server`. The index writes its errors as plain text, so the body is a usable
    /// message — but it's server-controlled, so it's truncated and never interpolated into anything
    /// but an error the UI shows as-is.
    private func check(status: Int, data: Data, route: String) throws {
        guard !(200..<300).contains(status) else { return }
        let body = plainText(data) ?? ""
        let message = body.isEmpty ? "HTTP \(status)" : String(body.prefix(200))
        throw ThunderBackendError.server(code: status, message: message)
    }

    private func plainText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Percent-encode a path segment. Base58 addresses and hex txids need none, but a user-supplied
    /// address reaches this too, and an unescaped `/` or `?` would silently change the route.
    private func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? segment
    }
}
