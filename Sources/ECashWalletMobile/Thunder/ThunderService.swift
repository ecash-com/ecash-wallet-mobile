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
final class ThunderService: WalletOps {
    private let loadMnemonic: (String) throws -> String?

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

    /// A Thunder address to receive at. NOTE: without the RPC we can't gap-scan for the next *unused*
    /// index, so this returns the index-0 address for now (a valid address to receive at). Real
    /// rotation / gap management arrives with the RPC history reads.
    func nextReceiveAddress(walletId: String) throws -> AddressInfo {
        let address = try wallet(for: walletId).address(at: 0)
        return AddressInfo(address: address.base58, index: 0)
    }

    func nextUnusedAddress(walletId: String) throws -> AddressInfo {
        try nextReceiveAddress(walletId: walletId)
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
