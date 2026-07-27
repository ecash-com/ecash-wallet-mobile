// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The Fuse-native Thunder engine — the `WalletOps` implementation for `.thunder` wallets, sitting
/// beside the bridged BDK `WalletManager` and routed to by `WalletFacade`. Thunder shares nothing with
/// Bitcoin (ed25519 keys, BLAKE3 addresses, Borsh serialization, a utreexo UTXO set), so none of BDK
/// applies; this is built on the Thunder crypto in this folder.
///
/// **The thin-node flow** (agreed with the Thunder dev, docs/thunder-sidechain-support.md §8b — the
/// node's half shipped in thunder-rust `2026-07-24-refactor`):
/// 1. derive addresses locally (`ThunderWallet`),
/// 2. `get_utxos(addresses)` — the node reads its full chain UTXO state, no seed required,
/// 3. select coins + build the transaction locally (`ThunderCoinSelector` + `ThunderTransaction`),
/// 4. sign locally (`ThunderWallet.authorize`),
/// 5. `submit_transaction`, where the node regenerates the utreexo proof.
/// The seed never leaves the phone and the node never holds it — the whole point (Golden Rule §2).
///
/// **Still gated:** transaction history. `get_utxos` returns only *unspent* outputs, so spends are
/// invisible and no history can be reconstructed client-side; `transactions` fails with a distinct
/// `.historyUnavailable` until the node exposes an address-scoped read for spent outputs.
///
/// The mnemonic is loaded APP-SIDE, transiently: `loadMnemonic` reads the secure store only when
/// derivation or signing needs it, and the derived `ThunderWallet` is dropped right after — the same
/// sign-on-demand shape as the BDK path, on this side of the bridge.
@MainActor
final class ThunderService: WalletOps {
    private let loadMnemonic: (String) throws -> String?
    /// Built per call so a Settings endpoint change takes effect without rebuilding the service.
    private let makeClient: @Sendable () -> ThunderRPCClient
    private let indexStore: ThunderAddressIndexStoring

    /// Last synced UTXO set per wallet. `WalletOps.balance` is synchronous (the UI reads it during
    /// layout), so a sync populates this and balance reads it — cached first, then refresh, exactly
    /// like the BDK path.
    private var utxoCache: [String: [ThunderPointedOutput]] = [:]

    /// How far past the highest revealed index a sync still looks. Mirrors BIP44's gap limit: money
    /// paid to an address we handed out but never recorded still has to be found.
    static let gapLimit: UInt32 = 20

    init(loadMnemonic: @escaping (String) throws -> String?,
         makeClient: @escaping @Sendable () -> ThunderRPCClient = {
             ThunderRPCClient(endpoint: NetworkRegistry.params(for: .thunder).defaultBackend)
         },
         indexStore: ThunderAddressIndexStoring = UserDefaultsThunderAddressIndexStore()) {
        self.loadMnemonic = loadMnemonic
        self.makeClient = makeClient
        self.indexStore = indexStore
    }

    // MARK: - Addresses (local — no RPC)

    /// A receive address. `unused: true` → the current revealed index (what Receive shows on open);
    /// `false` ("New address") → advance and persist the counter.
    ///
    /// The mnemonic is read on the main actor (a quick Keychain hit; reading it off-main trips the same
    /// isolation assertion that bit the facade), but the heavy work — PBKDF2 + SLIP-0010 + ed25519 +
    /// BLAKE3 — runs detached so the Receive sheet's present animation stays smooth.
    func receiveAddress(walletId: String, unused: Bool) async throws -> AddressInfo {
        let mnemonic = try requireMnemonic(walletId: walletId)
        let index: UInt32
        if unused {
            index = indexStore.revealedIndex(walletId: walletId)
        } else {
            index = indexStore.revealedIndex(walletId: walletId) + 1
            indexStore.setRevealedIndex(index, walletId: walletId)
        }
        return try await Task.detached(priority: .userInitiated) {
            let key = try ThunderKey.derive(mnemonic: mnemonic, index: index)
            return AddressInfo(address: key.address.base58, index: Int32(index))
        }.value
    }

    // MARK: - Balance / sync

    /// The last synced spendable balance. Zero before the first sync (the UI shows a cached value then
    /// refreshes), never a stale value from another wallet.
    func balance(walletId: String) throws -> Amount {
        Amount(sats: Int64(clamping: (utxoCache[walletId] ?? []).reduce(UInt64(0)) { $0 &+ $1.valueSats }))
    }

    /// Always zero: `get_utxos` reads the node's *state*, which only reflects connected blocks, so
    /// there is no mempool view to report as pending. A tx we just submitted therefore shows up at the
    /// next sync after it is mined, not before.
    func pendingBalance(walletId: String) throws -> Amount { Amount(sats: 0) }

    /// Scan this wallet's addresses (0 ..< revealed + gap limit) and refresh the cached UTXO set.
    func sync(walletId: String) async throws -> Amount {
        let utxos = try await fetchUtxos(walletId: walletId)
        utxoCache[walletId] = utxos
        return try balance(walletId: walletId)
    }

    /// Blocked on the node: see the type note and `ThunderError.historyUnavailable`.
    func transactions(walletId: String) throws -> [WalletTx] { throw ThunderError.historyUnavailable }

    // MARK: - Sending

    func send(walletId: String, to address: String,
              amount: Amount, feeRate: FeeRate) async throws -> WalletTx {
        guard let destination = ThunderAddress(base58: address) else { throw ThunderError.invalidAddress }
        guard amount.sats > 0 else { throw ThunderError.insufficientFunds(neededSats: 0, availableSats: 0) }
        let utxos = try await fetchUtxos(walletId: walletId)
        let selection = try ThunderCoinSelector.select(utxos: utxos,
                                                       targetSats: UInt64(amount.sats),
                                                       satPerByte: UInt64(max(0, feeRate.satPerVByte)))
        // Change goes to a fresh address, not back to an input's — reusing one would link the spend to
        // the coin it came from for anyone watching the chain.
        var outputs = [ThunderOutput(address: destination.bytes, content: .value(sats: UInt64(amount.sats)))]
        if selection.changeSats > 0 {
            let change = try nextChangeAddress(walletId: walletId)
            outputs.append(ThunderOutput(address: change.bytes, content: .value(sats: selection.changeSats)))
        }
        return try await build(walletId: walletId, selection: selection, outputs: outputs,
                               netSats: -(amount.sats + Int64(clamping: selection.feeSats)))
    }

    /// True "Max": drain every spendable UTXO to `address`, fee taken out of the total.
    func sweep(walletId: String, to address: String, feeRate: FeeRate) async throws -> WalletTx {
        guard let destination = ThunderAddress(base58: address) else { throw ThunderError.invalidAddress }
        let utxos = try await fetchUtxos(walletId: walletId)
        let selection = try ThunderCoinSelector.selectAll(utxos: utxos,
                                                          satPerByte: UInt64(max(0, feeRate.satPerVByte)))
        let sent = selection.totalInputSats - selection.feeSats
        let outputs = [ThunderOutput(address: destination.bytes, content: .value(sats: sent))]
        return try await build(walletId: walletId, selection: selection, outputs: outputs,
                               netSats: -Int64(clamping: selection.totalInputSats))
    }

    /// Splitting coins guards against the eCash fork's replay exposure — a concern that belongs to the
    /// Bitcoin/eCash chains, not to Thunder, which is its own chain with its own signature scheme.
    func splitToSelf(walletId: String, feeRate: FeeRate) async throws -> WalletTx {
        throw ThunderError.unsupportedOperation
    }

    /// Nothing to split (see `splitToSelf`) — reporting zeros is what keeps the Settings row and the
    /// Home nudge hidden for Thunder wallets.
    func splitSummary(walletId: String) throws -> SplitSummary {
        SplitSummary(spendableSats: 0, needsSplitSats: 0, needsSplitCount: 0)
    }

    // MARK: - Internals

    private func requireMnemonic(walletId: String) throws -> String {
        guard let mnemonic = try loadMnemonic(walletId), !mnemonic.isEmpty else {
            throw ThunderError.mnemonicUnavailable(walletId: walletId)
        }
        return mnemonic
    }

    /// Derive this wallet's address window and ask the node for its UTXOs. Unspendable outputs
    /// (withdrawals, which consensus refuses to let anyone spend) are dropped here, so they can't
    /// inflate a balance or be picked by coin selection.
    private func fetchUtxos(walletId: String) async throws -> [ThunderPointedOutput] {
        let mnemonic = try requireMnemonic(walletId: walletId)
        let window = Int(indexStore.revealedIndex(walletId: walletId) + Self.gapLimit) + 1
        let addresses = try await Task.detached(priority: .userInitiated) {
            try ThunderWallet(mnemonic: mnemonic).addresses(count: window).map(\.base58)
        }.value
        let client = makeClient()
        return try await client.getUtxos(addresses: addresses).compactMap(\.spendable)
    }

    /// Sign `selection` + `outputs` and submit. Shared by send and sweep — the only difference between
    /// them is how the outputs were chosen.
    private func build(walletId: String,
                       selection: ThunderCoinSelection,
                       outputs: [ThunderOutput],
                       netSats: Int64) async throws -> WalletTx {
        let mnemonic = try requireMnemonic(walletId: walletId)
        let searchLimit = Int(indexStore.revealedIndex(walletId: walletId) + Self.gapLimit) + 1
        let transaction = ThunderTransaction(inputs: selection.inputs.map { $0.asInput() }, outputs: outputs)
        let inputAddresses = selection.inputs.map(\.address)

        // Derive + sign off the main actor: this is the only moment the ed25519 secret exists, and it
        // is dropped when the task returns (Golden Rule §2).
        let authorized = try await Task.detached(priority: .userInitiated) {
            try ThunderWallet(mnemonic: mnemonic).authorize(transaction,
                                                            inputAddresses: inputAddresses,
                                                            searchLimit: max(searchLimit, ThunderWallet.defaultAddressSearchLimit))
        }.value

        let txid = try await makeClient().submitTransaction(authorized)

        // Drop the spent coins from the cache so an immediate second send can't reselect them. The
        // change output isn't added back — it isn't in the node's state until the tx is mined, and
        // `pendingBalance` is honest about that.
        let spent = Set(selection.inputs.map { $0.utxoHash() })
        utxoCache[walletId] = (utxoCache[walletId] ?? []).filter { !spent.contains($0.utxoHash()) }

        return WalletTx(txid: txid, netSats: netSats, feeSats: Int64(clamping: selection.feeSats),
                        confirmations: 0, timestampEpochSeconds: nil, isRBF: false)
    }

    /// A fresh change address: advance and persist the revealed counter, so change never lands on an
    /// address the Receive screen might hand out later (and so the next sync's window covers it).
    private func nextChangeAddress(walletId: String) throws -> ThunderAddress {
        let mnemonic = try requireMnemonic(walletId: walletId)
        let index = indexStore.revealedIndex(walletId: walletId) + 1
        indexStore.setRevealedIndex(index, walletId: walletId)
        return try ThunderKey.derive(mnemonic: mnemonic, index: index).address
    }
}
