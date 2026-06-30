// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Signet faucet client — a ConnectRPC **unary** call over HTTP+JSON, reusing the same
/// `ConnectRPCClient` transport as the CoinNews read API (no protobuf runtime). Dispenses valueless
/// test coins to a receive address.
///
/// Wire format (proto3 JSON): `POST <base>/faucet.v1.FaucetService/DispenseCoins` with body
/// `{"destination":"<addr>","amount":<double>}`; success → `{"txid":"…"}`; error → a non-2xx Connect
/// envelope `{"code","message"}` (e.g. "faucet limit reached, try again later").
struct FaucetClient: Sendable {
    private let rpc: ConnectRPCClient
    private static let service = "faucet.v1.FaucetService"

    init(endpoint: URL) {
        self.rpc = ConnectRPCClient(baseURL: endpoint)
    }

    /// Request `amount` coins to `destination`. Returns the funding txid. Throws `FaucetError`.
    func dispense(to destination: String, amount: Double) async throws -> String {
        do {
            let res: DispenseResponse = try await rpc.unary(
                service: Self.service, method: "DispenseCoins",
                request: DispenseRequest(destination: destination, amount: amount))
            return res.txid
        } catch let error as CoinNewsError {
            throw FaucetError.from(error)
        }
    }

    // `amount` is a `Double` so it serializes as a JSON number for the proto `double` field.
    private struct DispenseRequest: Encodable {
        let destination: String
        let amount: Double
    }
    private struct DispenseResponse: Decodable {
        let txid: String
    }
}

/// Faucet failures, mapped to user-safe strings. The server's own message (e.g. the rate-limit text)
/// is already user-appropriate, so we surface it verbatim for `.server`.
enum FaucetError: Error, Equatable {
    case server(String)   // a Connect `{"message"}` from the faucet (e.g. "faucet limit reached…")
    case network          // couldn't reach the faucet
    case unknown          // bad URL / decode / no message

    static func from(_ error: CoinNewsError) -> FaucetError {
        switch error {
        case .network:
            return .network
        case .server(_, let message):
            if let message, !message.isEmpty { return .server(message) }
            return .unknown
        case .badURL, .decode:
            return .unknown
        }
    }

    var userMessage: String {
        switch self {
        case .server(let message): return message
        case .network: return "Couldn't reach the faucet. Check your connection and try again."
        case .unknown: return "The faucet request failed. Try again later."
        }
    }
}
