// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The Fuse-native Thunder engine — the `WalletOps` implementation for `.thunder` wallets, sitting
/// beside the bridged BDK `WalletManager` and routed to by `WalletFacade`. Built on the Thunder crypto
/// that already exists (`ThunderKey` / `ThunderWallet` / Borsh / authorization).
///
/// STATUS: skeleton. Address derivation is LOCAL and works now; balance / sync / history / send need
/// the Thunder node RPC and currently throw `.backendUnavailable`. THIN-NODE FLOW (decided 2026-07-23,
/// docs/thunder-sidechain-support.md §8b): the phone does everything except fetch UTXOs and relay —
/// (1) derive addresses locally, (2) `get_utxos(addresses)` from the node, (3) select coins + build the
/// tx + sign locally (our Borsh + `ThunderWallet.authorize`), (4) `submit_transaction`, which fills the
/// utreexo proof node-side (so the phone never touches the accumulator). Pending: the node's
/// `get_utxos` / balance / history RPCs (dev implementing) + our RPC client + coin-selector.
///
/// The mnemonic is loaded APP-SIDE, transiently (Golden Rule §2): `loadMnemonic` reads the secure
/// store for a walletId only when derivation/signing needs it, and the derived `ThunderWallet` is
/// dropped right after — the same sign-on-demand shape as the BDK path, on this side of the bridge.
@MainActor
final class ThunderService: WalletOps {
    private let loadMnemonic: (String) throws -> String?

    /// Per-wallet highest index handed out by "New address". In-memory only (resets on relaunch) —
    /// proper gap management / used-address tracking needs the Thunder RPC history; until then this
    /// just lets the Receive screen rotate through freshly-derived addresses.
    private var revealedIndex: [String: UInt32] = [:]

    init(loadMnemonic: @escaping (String) throws -> String?) {
        self.loadMnemonic = loadMnemonic
    }

    // MARK: - Local (works today, no RPC)

    /// A receive address, derived OFF the main actor. `unused: true` → index 0 (the default shown when
    /// Receive opens); `false` ("New address") → advance a local rotation index (deriving a fresh
    /// address needs no RPC — only knowing which are *used* would). The mnemonic is read on the main
    /// actor (a quick Keychain access, and reading it off-main would trip the same isolation assertion
    /// that bit the facade), but the heavy work — PBKDF2 + SLIP-0010 + ed25519 + BLAKE3 — runs in a
    /// detached task so the Receive sheet's present animation stays smooth.
    func receiveAddress(walletId: String, unused: Bool) async throws -> AddressInfo {
        guard let mnemonic = try loadMnemonic(walletId), !mnemonic.isEmpty else {
            throw ThunderError.mnemonicUnavailable(walletId: walletId)
        }
        let index: UInt32
        if unused {
            index = 0
        } else {
            index = (revealedIndex[walletId] ?? 0) + 1
            revealedIndex[walletId] = index
        }
        return try await Task.detached(priority: .userInitiated) {
            let key = try ThunderKey.derive(mnemonic: mnemonic, index: index)
            return AddressInfo(address: key.address.base58, index: Int32(index))
        }.value
    }

    // MARK: - RPC-gated (throw until the Thunder node RPC is wired)

    func balance(walletId: String) throws -> Amount { throw ThunderError.backendUnavailable }
    func pendingBalance(walletId: String) throws -> Amount { throw ThunderError.backendUnavailable }
    func sync(walletId: String) async throws -> Amount { throw ThunderError.backendUnavailable }
    func transactions(walletId: String) throws -> [WalletTx] { throw ThunderError.backendUnavailable }
    func send(walletId: String, to address: String,
              amount: Amount, feeRate: FeeRate) async throws -> WalletTx {
        throw ThunderError.backendUnavailable
    }
    // Thunder sweep is a distinct construction (drain all ed25519 UTXOs client-side) — deferred with
    // the rest of the RPC ops; for now it fails loud like the others.
    func sweep(walletId: String, to address: String, feeRate: FeeRate) async throws -> WalletTx {
        throw ThunderError.backendUnavailable
    }
    func splitToSelf(walletId: String, feeRate: FeeRate) async throws -> WalletTx {
        throw ThunderError.backendUnavailable
    }
    // No fork-airdrop replay concern for Thunder (its own chain, ed25519) — nothing to split.
    func splitSummary(walletId: String) throws -> SplitSummary {
        SplitSummary(spendableSats: 0, needsSplitSats: 0, needsSplitCount: 0)
    }
}
