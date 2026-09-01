// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The drivechain-esplora REST client: route composition, the plain-text responses, and error mapping.
///
/// Everything runs through the injected `fetch` seam, so there is no server and no network — the same
/// shape `ThunderRPCTests` uses. If the index ever changes a route or a response encoding, these are
/// what should fail first.
@Suite struct ThunderEsploraClientTests {

    /// Records the URLs (and bodies) a client asked for, and replays canned answers by path suffix.
    private final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String] = []
        private var _bodies: [Data] = []
        /// Path suffix → (body, status). Longest match wins, so `/utxo` beats `/address/…`.
        var routes: [String: (String, Int)] = [:]
        var fallback: (String, Int) = ("[]", 200)
        /// When set, every request throws — standing in for offline/DNS/TLS failure.
        var throwsTransportError = false

        var urls: [String] { lock.withLock { _urls } }
        var bodies: [Data] { lock.withLock { _bodies } }

        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            if throwsTransportError { throw URLError(.notConnectedToInternet) }
            let url = request.url?.absoluteString ?? ""
            lock.withLock {
                _urls.append(url)
                if let body = request.httpBody { _bodies.append(body) }
            }
            let match = routes.keys.filter { url.hasSuffix($0) }.max(by: { $0.count < $1.count })
            let (body, status) = match.flatMap { routes[$0] } ?? fallback
            return (Data(body.utf8), status)
        }

        func client(endpoint: String = "https://index.example/thunder") -> ThunderEsploraClient {
            ThunderEsploraClient(endpoint: endpoint) { [self] in try await fetch($0) }
        }
    }

    private static let address = "38VvRdmcQREr1UAcZma98WLFVpAp"

    // MARK: - Route composition

    @Test func routesHangOffTheMountPath() async throws {
        let stub = Stub()
        stub.routes = ["/blocks/tip/height": ("1234", 200)]
        _ = try await stub.client().tipHeight()
        #expect(stub.urls == ["https://index.example/thunder/blocks/tip/height"])
    }

    /// The index mounts its routes at the base, so a trailing slash would produce `//blocks/...`,
    /// which it answers with a 404. Verified against the live endpoint: `/thunder/` is itself a 404.
    @Test func aTrailingSlashOnTheEndpointIsStripped() async throws {
        let stub = Stub()
        stub.routes = ["/blocks/tip/height": ("7", 200)]
        _ = try await stub.client(endpoint: "https://index.example/thunder///").tipHeight()
        #expect(stub.urls == ["https://index.example/thunder/blocks/tip/height"])
    }

    @Test func addressRoutesCarryTheAddress() async throws {
        let stub = Stub()
        stub.routes = ["/utxo": ("[]", 200), "/txs/chain": ("[]", 200)]
        let client = stub.client()
        _ = try await client.addressUTXOs(Self.address)
        _ = try await client.addressTxs(Self.address)
        _ = try await client.addressTxs(Self.address, lastSeen: "deadbeef")

        #expect(stub.urls[0].hasSuffix("/address/\(Self.address)/utxo"))
        #expect(stub.urls[1].hasSuffix("/address/\(Self.address)/txs/chain"))
        #expect(stub.urls[2].hasSuffix("/address/\(Self.address)/txs/chain/deadbeef"))
    }

    /// A user-supplied address reaches this path too, and an unescaped `/` or `?` would silently
    /// change which route was called rather than failing.
    @Test func aPathSeparatorInAnAddressCannotEscapeTheRoute() async throws {
        let stub = Stub()
        _ = try? await stub.client().addressUTXOs("abc/../../tx")
        let url = try #require(stub.urls.first)
        #expect(url.hasPrefix("https://index.example/thunder/address/"))
        #expect(!url.contains("/../"))
    }

    // MARK: - Reads

    @Test func tipHeightParsesPlainText() async throws {
        let stub = Stub()
        stub.routes = ["/blocks/tip/height": ("  4096\n", 200)]
        #expect(try await stub.client().tipHeight() == 4096)
    }

    /// An index that has walked no blocks answers 404 with a message, not 0. That is the live
    /// endpoint's current state, and it must not read to the user as "can't connect" — nothing is
    /// wrong with the phone or the endpoint.
    @Test func anEmptyIndexIsItsOwnErrorNotANetworkFailure() async throws {
        let stub = Stub()
        stub.routes = ["/blocks/tip/height": ("the index holds no blocks yet", 404)]
        await #expect(throws: ThunderBackendError.indexEmpty) {
            try await stub.client().tipHeight()
        }
    }

    // MARK: - Broadcast

    /// `POST /tx` relays its body into the node's `submit_transaction` unchanged, so the body must be
    /// exactly what the RPC client sends as `params[0]`. Pinning that is what lets the two backends
    /// share the whole authorization path.
    @Test func broadcastPostsTheSameJSONTheRPCPathSendsAndReadsAPlainTextTxid() async throws {
        let stub = Stub()
        stub.routes = ["/tx": ("abc123", 200)]
        let authorized = try Self.signedTransaction()

        let txid = try await stub.client().broadcast(authorized)
        #expect(txid == "abc123")

        let posted = try #require(stub.bodies.first)
        let expected = try JSONEncoder().encode(ThunderRPCAuthorizedTransaction(authorized: authorized))
        // Compared as parsed JSON, not as bytes: `JSONEncoder` gives no key-order guarantee, and the
        // claim being pinned is that the two backends send the same *value*, not the same byte layout.
        #expect(try JSONSerialization.jsonObject(with: posted) as? NSDictionary
                == JSONSerialization.jsonObject(with: expected) as? NSDictionary)

        // …and the shape itself: an authorized transaction with an empty (node-regenerated) proof.
        let json = try #require(try JSONSerialization.jsonObject(with: posted) as? [String: Any])
        let transaction = try #require(json["transaction"] as? [String: Any])
        #expect(transaction["inputs"] != nil)
        #expect(transaction["outputs"] != nil)
        let proof = try #require(transaction["proof"] as? [String: Any])
        #expect((proof["targets"] as? [Any])?.isEmpty == true)
        #expect((json["authorizations"] as? [Any])?.count == 1)
    }

    @Test func broadcastSurfacesTheServersRejectionMessage() async throws {
        let stub = Stub()
        stub.routes = ["/tx": ("transaction rejected: bad proof", 400)]
        await #expect(throws: ThunderBackendError.server(code: 400,
                                                         message: "transaction rejected: bad proof")) {
            try await stub.client().broadcast(try Self.signedTransaction())
        }
    }

    // MARK: - Errors

    @Test func aTransportFailureIsANetworkError() async throws {
        let stub = Stub()
        stub.throwsTransportError = true
        await #expect(throws: ThunderBackendError.network) {
            try await stub.client().addressUTXOs(Self.address)
        }
    }

    @Test func unparseableJSONIsReportedByRouteNotByContent() async throws {
        let stub = Stub()
        stub.routes = ["/utxo": ("not json at all", 200)]
        await #expect(throws: ThunderBackendError.malformedResponse("decode address utxo")) {
            try await stub.client().addressUTXOs(Self.address)
        }
    }

    /// A non-HTTP endpoint (a pasted Electrum `ssl://` URL, say) must fail as configuration rather
    /// than be handed to URLSession.
    @Test func aNonHTTPEndpointIsRejectedAsBadURL() async throws {
        let stub = Stub()
        let client = ThunderEsploraClient(endpoint: "ssl://index.example:50002") { [stub] in
            try await stub.fetch($0)
        }
        await #expect(throws: ThunderBackendError.badURL("ssl://index.example:50002")) {
            try await client.tipHeight()
        }
        #expect(stub.urls.isEmpty)   // never reached the transport
    }

    // MARK: - Helpers

    /// A real signed transaction, so the broadcast body is the genuine article rather than a fixture.
    private static func signedTransaction() throws -> AuthorizedThunderTransaction {
        let mnemonic = "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon about"
        let wallet = try ThunderWallet(mnemonic: mnemonic)
        let key = try ThunderKey.derive(mnemonic: mnemonic, index: 0)
        let utxo = ThunderPointedOutput(
            outPoint: .regular(txid: [UInt8](repeating: 0x11, count: 32), vout: 0),
            output: ThunderOutput(address: key.address.bytes, content: .value(sats: 10_000)))
        let tx = ThunderTransaction(
            inputs: [utxo.asInput()],
            outputs: [ThunderOutput(address: key.address.bytes, content: .value(sats: 9_800))])
        return try wallet.authorize(tx, inputAddresses: [key.address],
                                    searchLimit: ThunderWallet.defaultAddressSearchLimit)
    }
}
