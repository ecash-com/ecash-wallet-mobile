// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The Thunder JSON-RPC wire layer. The JSON here is written out by hand to match thunder-rust's
/// **serde** output — including the two places its OpenAPI schema disagrees with serde (32/64-number
/// byte arrays where the schema claims `String`). If the node ever changes those shapes, these tests
/// are what should fail first.
@Suite struct ThunderRPCTests {

    private static let address = "38VvRdmcQREr1UAcZma98WLFVpAp"   // index-0 golden (ThunderWallet)

    // MARK: - Decoding `get_utxos`

    @Test func decodesValueUtxo() throws {
        let json = """
        [{"outpoint":{"Regular":{"txid":"\(String(repeating: "11", count: 32))","vout":2}},
          "output":{"address":"\(Self.address)","content":{"Value":12345}}}]
        """
        let utxos = try JSONDecoder().decode([ThunderRPCPointedOutput].self, from: Data(json.utf8))
        #expect(utxos.count == 1)
        let spendable = try #require(utxos[0].spendable)
        #expect(spendable.valueSats == 12345)
        #expect(spendable.address.base58 == Self.address)
        #expect(spendable.outPoint == .regular(txid: [UInt8](repeating: 0x11, count: 32), vout: 2))
    }

    @Test func withdrawalUtxoIsNotSpendable() throws {
        // Consensus rejects spending a withdrawal output, so it must never reach coin selection.
        let json = """
        [{"outpoint":{"Regular":{"txid":"\(String(repeating: "22", count: 32))","vout":0}},
          "output":{"address":"\(Self.address)",
                    "content":{"Withdrawal":{"value_sats":1000,"main_fee_sats":300,
                                             "main_address":"1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"}}}}]
        """
        let utxos = try JSONDecoder().decode([ThunderRPCPointedOutput].self, from: Data(json.utf8))
        #expect(utxos[0].spendable == nil)
        #expect(utxos[0].output.content.valueSats == 1300)   // payout + mainchain fee
    }

    @Test func decodesCoinbaseAndDepositOutpoints() throws {
        let json = """
        [{"outpoint":{"Coinbase":{"merkle_root":"\(String(repeating: "33", count: 32))","vout":1}},
          "output":{"address":"\(Self.address)","content":{"Value":7}}},
         {"outpoint":{"Deposit":{"txid":"\(String(repeating: "ab", count: 31))cd","vout":4}},
          "output":{"address":"\(Self.address)","content":{"Value":9}}}]
        """
        let utxos = try JSONDecoder().decode([ThunderRPCPointedOutput].self, from: Data(json.utf8))
        #expect(utxos[0].outpoint.outPoint == .coinbase(merkleRoot: [UInt8](repeating: 0x33, count: 32), vout: 1))

        // A Deposit wraps a MAINCHAIN bitcoin::OutPoint, whose txid hex is display order — reversed
        // relative to the internal bytes we Borsh-encode. So the leading "ab…cd" must land as "cd…ab".
        guard case let .deposit(txid, vout) = utxos[1].outpoint.outPoint else {
            Issue.record("expected a deposit outpoint"); return
        }
        #expect(vout == 4)
        #expect(txid.first == 0xcd)
        #expect(txid.last == 0xab)
    }

    @Test func depositOutpointRoundTripsThroughJSON() throws {
        // Encode → decode must land on the same internal bytes, or a deposited coin would be spent
        // with a hash the node can't match.
        var internalBytes = [UInt8](repeating: 0, count: 32)
        internalBytes[0] = 0xde; internalBytes[31] = 0xad
        let original = ThunderRPCOutPoint(.deposit(txid: internalBytes, vout: 1))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ThunderRPCOutPoint.self, from: data) == original)
    }

    @Test func unknownContentFailsLoudly() {
        let json = """
        [{"outpoint":{"Regular":{"txid":"\(String(repeating: "11", count: 32))","vout":0}},
          "output":{"address":"\(Self.address)","content":{"Mystery":1}}}]
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([ThunderRPCPointedOutput].self, from: Data(json.utf8))
        }
    }

    // MARK: - Encoding `submit_transaction`

    /// The submit payload's exact shape: tuple inputs, a byte-array hash, an empty proof, and
    /// authorizations as number arrays (NOT the hex strings the OpenAPI schema advertises).
    @Test func authorizedTransactionEncodesToSerdeShape() throws {
        let utxoHash = [UInt8](repeating: 0x0f, count: 32)
        let tx = ThunderTransaction(
            inputs: [.init(outPoint: .regular(txid: [UInt8](repeating: 0x11, count: 32), vout: 1),
                           utxoHash: utxoHash)],
            outputs: [ThunderOutput(address: ThunderAddress(base58: Self.address)!.bytes,
                                    content: .value(sats: 500))])
        let authorized = AuthorizedThunderTransaction(
            transaction: tx,
            authorizations: [ThunderAuthorization(verifyingKey: [UInt8](repeating: 1, count: 32),
                                                  signature: [UInt8](repeating: 2, count: 64))])

        let data = try JSONEncoder().encode(ThunderRPCAuthorizedTransaction(authorized: authorized))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transaction = try #require(root["transaction"] as? [String: Any])

        // inputs: [[outpoint, [32 numbers]]]
        let inputs = try #require(transaction["inputs"] as? [[Any]])
        #expect(inputs.count == 1)
        #expect((inputs[0][0] as? [String: Any])?["Regular"] != nil)
        let hash = try #require(inputs[0][1] as? [Int])
        #expect(hash.count == 32)
        #expect(hash.allSatisfy { $0 == 15 })

        // proof: present but empty — required by serde, overwritten by the node.
        let proof = try #require(transaction["proof"] as? [String: Any])
        #expect((proof["targets"] as? [Int])?.isEmpty == true)
        #expect((proof["hashes"] as? [String])?.isEmpty == true)

        // outputs: address as base58, content externally tagged.
        let outputs = try #require(transaction["outputs"] as? [[String: Any]])
        #expect(outputs[0]["address"] as? String == Self.address)
        #expect((outputs[0]["content"] as? [String: Any])?["Value"] as? Int == 500)

        // authorizations: number arrays, not hex strings.
        let authorizations = try #require(root["authorizations"] as? [[String: Any]])
        #expect((authorizations[0]["verifying_key"] as? [Int])?.count == 32)
        #expect((authorizations[0]["signature"] as? [Int])?.count == 64)
    }

    // MARK: - Client envelope

    /// Capture the request body and reply with canned JSON — no server involved.
    private func client(reply: String, status: Int = 200,
                        capture: (@Sendable (Data) -> Void)? = nil) -> ThunderRPCClient {
        ThunderRPCClient(endpoint: "http://127.0.0.1:6009") { request in
            if let body = request.httpBody { capture?(body) }
            return (Data(reply.utf8), status)
        }
    }

    @Test func sendsJSONRPCEnvelopeWithPositionalParams() async throws {
        let captured = LockedBox()
        let client = client(reply: #"{"jsonrpc":"2.0","id":1,"result":[]}"#) { captured.set($0) }
        _ = try await client.getUtxos(addresses: ["a", "b"])

        let body = try #require(captured.get())
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["method"] as? String == "get_utxos")
        // params is positional: one argument, itself the address list.
        let params = try #require(json["params"] as? [[String]])
        #expect(params == [["a", "b"]])
    }

    @Test func parsesResultAndError() async throws {
        let ok = client(reply: #"{"jsonrpc":"2.0","id":1,"result":"deadbeef"}"#)
        #expect(try await ok.submitTransaction(Self.dummyAuthorized()) == "deadbeef")

        let failing = client(reply: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"bad tx"}}"#)
        do {
            _ = try await failing.submitTransaction(Self.dummyAuthorized())
            Issue.record("expected a server error")
        } catch let error as ThunderRPCError {
            #expect(error == .server(code: -32000, message: "bad tx"))
        }
    }

    @Test func mapsTransportAndParseFailures() async throws {
        let garbage = client(reply: "<html>nope</html>")
        do {
            _ = try await garbage.blockCount(); Issue.record("expected malformedResponse")
        } catch let error as ThunderRPCError {
            #expect(error == .malformedResponse("decode getblockcount result"))
        }

        let http500 = client(reply: "server exploded", status: 500)
        do {
            _ = try await http500.blockCount(); Issue.record("expected server error")
        } catch let error as ThunderRPCError {
            #expect(error == .server(code: 500, message: "HTTP 500"))
        }

        let offline = ThunderRPCClient(endpoint: "http://127.0.0.1:6009") { _ in
            throw ThunderRPCError.network
        }
        do {
            _ = try await offline.blockCount(); Issue.record("expected network error")
        } catch let error as ThunderRPCError {
            #expect(error == .network)
        }
    }

    /// An unset/blank endpoint must fail before any request is attempted. (Note `URL(string:)` is
    /// lenient — it happily parses things like "not a url" — so the empty string is the honest case
    /// here, and it's the one a missing Settings override would actually produce.)
    @Test func rejectsUnusableEndpoint() async {
        let client = ThunderRPCClient(endpoint: "") { _ in
            Issue.record("must not reach the network with no endpoint")
            return (Data(), 200)
        }
        do {
            _ = try await client.blockCount(); Issue.record("expected badURL")
        } catch let error as ThunderRPCError {
            #expect(error == .badURL(""))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    private static func dummyAuthorized() -> AuthorizedThunderTransaction {
        AuthorizedThunderTransaction(transaction: ThunderTransaction(inputs: [], outputs: []),
                                     authorizations: [])
    }
}

/// Minimal thread-safe box so a `@Sendable` fetch closure can hand the captured body back.
final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
}
