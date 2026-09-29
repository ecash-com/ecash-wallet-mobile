// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Read access to a BIP300 enforcer's view of the mainchain: which sidechains are active, what each
/// treasury holds, and what's being voted on. `EnforcerClient` is the live implementation. View
/// models depend on this protocol so their tests run on canned data with no network.
protocol EnforcerFetching: Sendable {
    func chainTip() async throws -> EnforcerChainTip
    func bip300Constants() async throws -> Bip300Constants
    /// Every active sidechain, in slot order.
    func sidechains() async throws -> [Sidechain]
    /// The slot's treasury, or `nil` if it has had no deposits yet.
    func treasury(slot: Int) async throws -> SidechainTreasury?
    /// Sidechains being voted into a slot, in slot order.
    func sidechainProposals() async throws -> [SidechainProposal]
    func withdrawalBundleProposals(slot: Int) async throws -> [WithdrawalBundleProposal]
}

/// Enforcer failures, kept coarse: callers show a "sidechain info unavailable" state and retry,
/// they don't branch on the cause.
enum EnforcerError: Error, Equatable {
    /// Couldn't reach the enforcer.
    case network
    /// The enforcer answered with an error. `message` is its Connect `{"message"}`, for logs.
    case server(status: Int, message: String?)
    /// The answer didn't have the expected shape (an enforcer on an incompatible version).
    case malformed(String)
    /// A slot outside 0–255 was asked for. Caught here so it never reaches the wire.
    case invalidSlot(Int)

    static func from(_ error: CoinNewsError) -> EnforcerError {
        switch error {
        case .network: return .network
        case .server(let status, let message): return .server(status: status, message: message)
        case .decode(let detail): return .malformed(detail)
        case .badURL: return .malformed("bad enforcer URL")
        }
    }
}
