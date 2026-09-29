// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// BIP300 mainchain state as the enforcer reports it (`EnforcerClient`). These are the app's own
/// shapes. The proto3-JSON wire types stay private to the client, so a change in the enforcer's
/// encoding never reaches a view.
///
/// Amounts are `Int64` sats (CLAUDE.md §6). Heights and counts are `Int`: this is the Fuse app
/// module, native Swift on both platforms, so `Int` is 64-bit here. The 32-bit-`Int` warning applies
/// to transpiled code only.

/// An **active** sidechain: one whose slot the miners have voted in. Only these may receive
/// deposits. An M5 to an inactive slot is an ordinary anyone-can-spend output, so the coins are lost
/// (`docs/sidechain-deposits.md` §3a).
struct Sidechain: Equatable, Sendable, Identifiable {
    /// BIP300 slot number, 0–255. Stable for the life of the sidechain, so it is the identity.
    let slot: Int
    let title: String
    let description: String
    let voteCount: Int
    let proposalHeight: Int
    let activationHeight: Int

    var id: Int { slot }
}

/// A sidechain's treasury UTXO (the "CTIP"). A deposit must spend it and recreate it with more value
/// in it. `nil` where it's used means the slot has had no deposits yet, which is not the same as a
/// treasury holding zero sats.
struct SidechainTreasury: Equatable, Sendable {
    /// Display-order txid (the enforcer's `ReverseHex`), the same form Esplora and explorers use.
    let txid: String
    let vout: Int
    let valueSats: Int64
    /// How many times this treasury has moved (deposits plus withdrawals). Useful for spotting that
    /// it changed between reading it and building on it.
    let sequenceNumber: Int64
}

/// A sidechain being voted into a slot. It can't take deposits until it activates.
struct SidechainProposal: Equatable, Sendable, Identifiable {
    let slot: Int
    let title: String
    let description: String
    let voteCount: Int
    let proposalHeight: Int
    let proposalAge: Int

    var id: Int { slot }
}

/// A withdrawal bundle (M6) that miners are voting on for one sidechain.
struct WithdrawalBundleProposal: Equatable, Sendable, Identifiable {
    let m6id: String
    let voteCount: Int
    let proposalHeight: Int

    var id: String { m6id }
}

/// The block the enforcer has validated up to. Compare it with the wallet backend's tip before
/// trusting a CTIP: an enforcer that's behind reports a treasury that may already be spent.
struct EnforcerChainTip: Equatable, Sendable {
    let height: Int
    let blockHash: String
}

/// The BIP300 voting windows for this chain, in blocks. They set how long a withdrawal takes, so the
/// UI can state the real wait instead of a hardcoded "months".
struct Bip300Constants: Equatable, Sendable {
    let withdrawalBundleMaxAge: Int
    let withdrawalBundleInclusionThreshold: Int
    let usedSlotActivationThreshold: Int
    let unusedSlotActivationThreshold: Int
    /// The height from which BIP300 is enforced on this chain (the fork height on eCash).
    let activationHeight: Int
}
