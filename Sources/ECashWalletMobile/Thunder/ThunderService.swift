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
/// the Thunder node RPC (`create_transaction` / `submit_transaction` / address-scoped reads — see
/// docs/thunder-sidechain-support.md §8b, pending the Thunder dev) and currently throw
/// `.backendUnavailable`. When the RPC lands, this is where the client stitches RPC reads together
/// with local signing (`ThunderWallet.authorize`).
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

    /// Load the mnemonic and build a transient `ThunderWallet`. Callers use it and let it go.
    private func wallet(for walletId: String) throws -> ThunderWallet {
        guard let mnemonic = try loadMnemonic(walletId), !mnemonic.isEmpty else {
            throw ThunderError.mnemonicUnavailable(walletId: walletId)
        }
        return ThunderWallet(mnemonic: mnemonic)
    }

    // MARK: - Local (works today, no RPC)

    /// "New address" — reveal a FRESH address by advancing the local index. Deriving a new address
    /// needs no RPC (only knowing which are *used* would), so this genuinely rotates.
    func nextReceiveAddress(walletId: String) throws -> AddressInfo {
        let index = (revealedIndex[walletId] ?? 0) + 1
        let address = try wallet(for: walletId).address(at: index)
        revealedIndex[walletId] = index
        return AddressInfo(address: address.base58, index: Int32(index))
    }

    /// The default address shown when Receive opens: index 0. Real gap-scan for the lowest *unused*
    /// index needs the RPC history; until then it's the wallet's first address.
    func nextUnusedAddress(walletId: String) throws -> AddressInfo {
        let address = try wallet(for: walletId).address(at: 0)
        return AddressInfo(address: address.base58, index: 0)
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
}
