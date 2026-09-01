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
/// **The thin-client flow** (agreed with the Thunder dev, docs/thunder-sidechain-support.md §8b — the
/// node's half shipped in thunder-rust `2026-07-24-refactor`):
/// 1. derive addresses locally (`ThunderWallet`),
/// 2. ask the backend for those addresses' UTXOs — public data only, no seed required,
/// 3. select coins + build the transaction locally (`ThunderCoinSelector` + `ThunderTransaction`),
/// 4. sign locally (`ThunderWallet.authorize`),
/// 5. submit, where the node regenerates the utreexo proof.
/// The seed never leaves the phone and no server ever holds it — the whole point (Golden Rule §2).
///
/// **Where the facts come from is a `ThunderBackend`** — either a drivechain-esplora index (the
/// registry default: real heights, times and fees) or the node's own JSON-RPC (works against a bare
/// node, but can date nothing). Steps 1, 3 and 4 are identical either way, and the submitted JSON is
/// byte-identical, so the choice of backend can never change what gets signed. Rows a backend can't
/// date are stamped here from a local first-seen record (`datedNewestFirst`), in one place, so the
/// fallback rule doesn't drift per backend.
///
/// The mnemonic is loaded APP-SIDE, transiently: `loadMnemonic` reads the secure store only when
/// derivation or signing needs it, and the derived `ThunderWallet` is dropped right after — the same
/// sign-on-demand shape as the BDK path, on this side of the bridge.
@MainActor
final class ThunderService: WalletOps {
    private let loadMnemonic: (String) throws -> String?
    /// Built per call so a Settings endpoint change — URL *or* wire kind — takes effect without
    /// rebuilding the service.
    private let makeBackend: @Sendable () -> ThunderBackend
    private let indexStore: ThunderAddressIndexStoring
    private let firstSeenStore: ThunderFirstSeenStoring
    /// Clock seam so tests don't depend on the wall clock.
    private let now: @Sendable () -> Int64

    /// Last synced UTXO set per wallet. `WalletOps.balance` is synchronous (the UI reads it during
    /// layout), so a sync populates this and balance reads it — cached first, then refresh, exactly
    /// like the BDK path.
    private var utxoCache: [String: [ThunderPointedOutput]] = [:]

    /// Last rebuilt history per wallet. `WalletOps.transactions` is synchronous, so — like balance —
    /// a sync computes this and the read returns it.
    private var historyCache: [String: [WalletTx]] = [:]

    /// How far past the highest revealed index a sync still looks. Mirrors BIP44's gap limit: money
    /// paid to an address we handed out but never recorded still has to be found.
    static let gapLimit: UInt32 = 20

    /// How many extra gap-limit batches a sync will walk before giving up. 20 rounds = 400 addresses
    /// past the known window — far beyond any real wallet, and a hard stop so a server that called
    /// every address "used" could not make us derive forever.
    static let maxDiscoveryRounds = 20

    init(loadMnemonic: @escaping (String) throws -> String?,
         makeBackend: @escaping @Sendable () -> ThunderBackend = {
             let params = NetworkRegistry.params(for: WalletNetwork.thunder)
             return ThunderBackendFactory.make(kind: params.defaultBackendKind, url: params.defaultBackend)
         },
         indexStore: ThunderAddressIndexStoring = UserDefaultsThunderAddressIndexStore(),
         firstSeenStore: ThunderFirstSeenStoring = UserDefaultsThunderFirstSeenStore(),
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.loadMnemonic = loadMnemonic
        self.makeBackend = makeBackend
        self.indexStore = indexStore
        self.firstSeenStore = firstSeenStore
        self.now = now
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

    /// Always zero: neither backend has a mempool to report. The node's `get_utxos` reads its *state*,
    /// which only reflects connected blocks, and the index serves no mempool view either
    /// (`/address/{a}/txs/mempool` is always empty — it says so). A tx we just submitted therefore
    /// shows up at the next sync after it is mined, not before.
    func pendingBalance(walletId: String) throws -> Amount { Amount(sats: 0) }

    /// Scan this wallet's addresses (0 ..< revealed + gap limit), refresh the cached UTXO set, and
    /// rebuild history from the unspent + spent reads.
    /// Thunder derives its own address window on every sync (no BDK revealed-spk model), so a
    /// rescan is just a sync — there is no narrower window to widen.
    func balanceAsync(walletId: String) async throws -> Amount { try balance(walletId: walletId) }
    func pendingBalanceAsync(walletId: String) async throws -> Amount { try pendingBalance(walletId: walletId) }
    func transactionsAsync(walletId: String) async throws -> [WalletTx] { try transactions(walletId: walletId) }

    func rescan(walletId: String) async throws -> Amount {
        try await sync(walletId: walletId)
    }

    func sync(walletId: String) async throws -> Amount {
        let backend = makeBackend()
        let discovered = try await discoverWindow(walletId: walletId, backend: backend)
        let scan = try await backend.scan(addresses: discovered.addresses, knownUsed: discovered.used)
        utxoCache[walletId] = scan.utxos
        historyCache[walletId] = datedNewestFirst(scan.transactions, walletId: walletId)
        return try balance(walletId: walletId)
    }

    /// The window to scan, extended past the known one while coins keep turning up.
    ///
    /// **Why this is needed at all.** `revealedIndex` is local device state — a small integer in
    /// UserDefaults. Restore a wallet onto a new phone and it starts at 0, so the fixed
    /// `revealed + gap limit` window covers only the first 21 addresses. A wallet that had been used
    /// further down its address chain would show a *partial balance*. Nothing is ever lost (every
    /// index re-derives from the one seed), but "my money is gone" is not a thing a wallet should say
    /// — and Thunder has no watch-only xpub or BDK revealed-SPK store to recover the count from, so
    /// the app has to go and look.
    ///
    /// The rule is BIP44's: keep walking while any address in the trailing gap-limit stretch has been
    /// used, stop once a whole stretch is untouched. **That limit is real and this does not remove
    /// it** — coins sitting past 20 consecutive unused addresses stay undiscoverable, exactly as they
    /// are for BDK on the Bitcoin side. What it fixes is the common shape: a wallet used progressively
    /// down its chain, where every extension keeps finding more.
    ///
    /// Only a backend that can answer "used?" cheaply takes part (`usedAddresses` → nil means don't
    /// extend); the node RPC keeps the fixed window it has always had, because probing it batch by
    /// batch would cost a full UTXO-table scan each time.
    ///
    /// Whatever it finds is **persisted** to `revealedIndex`, so the wider window is free from then on —
    /// including for the send path, which never pays for discovery.
    private func discoverWindow(walletId: String, backend: ThunderBackend)
    async throws -> (addresses: [String], used: [String]?) {
        var addresses = try await addressWindow(walletId: walletId)
        guard var used = try await backend.usedAddresses(addresses) else { return (addresses, nil) }

        for _ in 0..<Self.maxDiscoveryRounds {
            // Extend only while the trailing stretch shows activity.
            let tail = Set(addresses.suffix(Int(Self.gapLimit)))
            guard used.contains(where: { tail.contains($0) }) else { break }

            let start = UInt32(addresses.count)
            let more = try await derivedAddresses(walletId: walletId,
                                                  indices: start..<(start + Self.gapLimit))
            guard let moreUsed = try await backend.usedAddresses(more) else { break }
            addresses += more
            used += moreUsed
        }

        // Record how far the chain actually goes, so this costs nothing next time. `addresses` is
        // index-ordered from 0, so an address's position IS its derivation index. The store is
        // monotonic, so this can only ever widen the window, never re-issue an old address.
        if let highest = used.compactMap({ addresses.firstIndex(of: $0) }).max() {
            indexStore.setRevealedIndex(UInt32(highest), walletId: walletId)
        }
        return (addresses, used)
    }

    /// Give every row a timestamp, then put the list newest-first.
    ///
    /// A backend that reports real block times (the Esplora index) leaves nothing to do here, and the
    /// list keeps the height-then-time order it already has. One that can't date a transaction at all
    /// (the node RPC — no per-tx height exists to ask for) returns undated rows, and those fall back
    /// to when this device first saw the txid: exactly right for a wallet in daily use, and
    /// arbitrary-but-*stable* for a freshly restored one, which beats reshuffling every launch.
    private func datedNewestFirst(_ transactions: [WalletTx], walletId: String) -> [WalletTx] {
        let undated = transactions.filter { $0.timestampEpochSeconds == nil }
        guard !undated.isEmpty else { return transactions }

        firstSeenStore.record(txids: Set(undated.map(\.txid)), walletId: walletId, now: now())
        let firstSeen = firstSeenStore.firstSeen(walletId: walletId)
        let stamped = transactions.map { tx -> WalletTx in
            guard tx.timestampEpochSeconds == nil, let seen = firstSeen[tx.txid] else { return tx }
            return WalletTx(txid: tx.txid, netSats: tx.netSats, feeSats: tx.feeSats,
                            confirmations: tx.confirmations, timestampEpochSeconds: seen,
                            isRBF: tx.isRBF, blockHeight: tx.blockHeight, vsize: tx.vsize,
                            coinNewsKind: tx.coinNewsKind, receivedSats: tx.receivedSats)
        }
        return stamped.sorted { ($0.timestampEpochSeconds ?? 0) > ($1.timestampEpochSeconds ?? 0) }
    }

    /// History rebuilt from `get_utxos` + `get_stxos` at the last sync (see `ThunderHistory` for what
    /// can and can't be derived — notably no fee, no height, no real confirmation depth).
    func transactions(walletId: String) throws -> [WalletTx] { historyCache[walletId] ?? [] }

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

    /// Same zeros regardless of what the Bitcoin check found — Thunder coins are ed25519/BLAKE3 and
    /// share no outpoints with Bitcoin, so nothing here can be a split candidate.
    func splitSummary(walletId: String, knownShared: [String], knownSafe: [String]) throws -> SplitSummary {
        try splitSummary(walletId: walletId)
    }

    func splitCandidates(walletId: String) throws -> [Utxo] { [] }

    // MARK: - Internals

    private func requireMnemonic(walletId: String) throws -> String {
        guard let mnemonic = try loadMnemonic(walletId), !mnemonic.isEmpty else {
            throw ThunderError.mnemonicUnavailable(walletId: walletId)
        }
        return mnemonic
    }

    /// Derive this wallet's address window and ask the backend for its UTXOs. Unspendable outputs
    /// (withdrawals, which consensus refuses to let anyone spend) are already dropped by the backend,
    /// so they can't inflate a balance or be picked by coin selection.
    private func fetchUtxos(walletId: String) async throws -> [ThunderPointedOutput] {
        let addresses = try await addressWindow(walletId: walletId)
        return try await makeBackend().spendableUTXOs(addresses: addresses)
    }

    /// This wallet's address window: 0 ..< revealed + gap limit.
    private func addressWindow(walletId: String) async throws -> [String] {
        let count = indexStore.revealedIndex(walletId: walletId) + Self.gapLimit + 1
        return try await derivedAddresses(walletId: walletId, indices: UInt32(0)..<count)
    }

    /// Addresses at `indices`. The mnemonic is loaded per call and dropped when the task returns —
    /// discovery derives in batches rather than holding the secret across the whole scan.
    private func derivedAddresses(walletId: String, indices: Range<UInt32>) async throws -> [String] {
        let mnemonic = try requireMnemonic(walletId: walletId)
        return try await Task.detached(priority: .userInitiated) {
            try ThunderWallet(mnemonic: mnemonic).addresses(indices: indices).map(\.base58)
        }.value
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

        let txid = try await makeBackend().submit(authorized)

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
