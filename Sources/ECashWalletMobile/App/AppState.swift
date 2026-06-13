// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // required for @Observable to drive the Android (Compose) UI in Fuse
import WalletService

/// Top-level, cross-screen app state. Owns the `WalletManager` (the WalletService seam) and
/// re-publishes its wallet list + selection as `@Observable` properties so SwiftUI/Compose update.
///
/// `WalletManager` is a plain class (not `@Observable`) so it stays bridge-agnostic; `AppState`
/// mirrors its state into observable stored props and calls `refresh()` after every mutation.
@MainActor
@Observable
final class AppState {
    private let manager: WalletManager

    /// Mirrors of `WalletManager` state — the observable surface the UI binds to.
    private(set) var wallets: [ManagedWallet] = []
    private(set) var selectedWalletId: String?

    /// The selected wallet's balance (cached first, then refreshed by `sync()`).
    private(set) var balance: Amount = .zero
    /// Sync lifecycle for the selected wallet, so the UI can show a spinner / error.
    private(set) var syncState: SyncState = .idle
    /// The selected wallet's transactions, newest first (pending at the top). Cached, then refreshed.
    private(set) var transactions: [WalletTx] = []

    /// Which main tab is showing — owned here so "See all" on Home can switch to Activity.
    var selectedTab: MainTab = .wallet

    /// Hide the balance on Home (the "eye" toggle). Persisted — privacy choices should stick.
    var balanceHidden: Bool {
        didSet { UserDefaults.standard.set(balanceHidden, forKey: "balanceHidden") }
    }

    private static let selectedWalletKey = "selectedWalletId"

    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    init() {
        // The public WalletManager() wires the real Keychain + JSON store + BDK factory internally
        // (those are WalletService implementation details — not part of the bridged surface).
        manager = WalletManager()
        balanceHidden = UserDefaults.standard.bool(forKey: "balanceHidden")
        try? manager.load()
        // Restore the active wallet across launches (manager.load defaults to the first wallet;
        // select is a no-op if the saved id no longer exists).
        if let saved = UserDefaults.standard.string(forKey: Self.selectedWalletKey) {
            manager.select(id: saved)
        }
        refresh()
    }

    // MARK: - Derived state

    /// Drives first-launch routing: empty → focused create/import; otherwise the main shell.
    var hasWallets: Bool { !wallets.isEmpty }

    var selectedWallet: ManagedWallet? {
        guard let id = selectedWalletId else { return nil }
        return wallets.first { $0.id == id }
    }

    /// The most recent transactions for the Home preview (full list lives on the Activity tab).
    var recentTransactions: [WalletTx] {
        Array(transactions.prefix(4))
    }

    /// Display unit label (sBTC / tBTC / BTC) for the selected wallet's network.
    var unitLabel: String {
        guard let network = selectedWallet?.network else { return "" }
        return NetworkRegistry.params(for: network).unitLabel
    }

    // MARK: - Mutations (mirror back after each)

    /// Create a new wallet on `network`, persist it, select it. Throws `WalletError` on failure.
    @discardableResult
    func createWallet(label: String, network: WalletNetwork) throws -> ManagedWallet {
        let wallet = try manager.createWallet(label: label, network: network)
        resetPerWalletState()   // the new wallet is auto-selected; don't show the old one's numbers
        refresh()
        return wallet
    }

    /// Import a wallet from a recovery phrase (validated by BDK in the factory), persist it,
    /// select it. Throws `WalletError.invalidMnemonic` on a bad phrase — never echoes the input.
    @discardableResult
    func importWallet(label: String, network: WalletNetwork, mnemonic: String) throws -> ManagedWallet {
        let wallet = try manager.importWallet(label: label, network: network, mnemonic: mnemonic)
        resetPerWalletState()   // the imported wallet is auto-selected
        refresh()
        return wallet
    }

    /// A default label for the next wallet ("Wallet 1", "Wallet 2", …). Renameable later (Slice 7).
    var nextDefaultWalletName: String { "Wallet \(wallets.count + 1)" }

    /// Vend a `CreateViewModel` wired to this manager (used by the Create flow). The VM is owned by
    /// the view; capturing `self` here is safe (no retain cycle — AppState doesn't hold the VM).
    func makeCreateViewModel() -> CreateViewModel {
        CreateViewModel(create: { label, network in
            _ = try self.createWallet(label: label, network: network)
        })
    }

    /// Vend an `ImportViewModel` wired to this manager (used by the Import flow).
    func makeImportViewModel() -> ImportViewModel {
        ImportViewModel(importWallet: { label, network, mnemonic in
            _ = try self.importWallet(label: label, network: network, mnemonic: mnemonic)
        })
    }

    /// Vend a `BackupViewModel` for the selected wallet, or nil if none is selected. The wallet
    /// id is captured at presentation time (same rule as Send — a switch mid-flow can't
    /// redirect which wallet's phrase is shown or marked backed up).
    func makeBackupViewModel() -> BackupViewModel? {
        guard let id = selectedWalletId else { return nil }
        return BackupViewModel(
            loadMnemonic: { try self.manager.mnemonic(for: id) },
            markBackedUp: {
                try self.manager.setBackedUp(id: id)
                self.refresh()   // flips `isBackedUp` → the Home warning disappears
            },
            authenticate: { reason in await DeviceAuth.authenticate(reason: reason) })
    }

    /// Vend a `SendViewModel` for the selected wallet, or nil if none is selected. Captures the
    /// wallet id at presentation time so a wallet switch mid-flow can't redirect the send.
    func makeSendViewModel() -> SendViewModel? {
        guard let id = selectedWalletId, let wallet = selectedWallet else { return nil }
        let params = NetworkRegistry.params(for: wallet.network)
        return SendViewModel(
            balance: balance,
            unitLabel: params.unitLabel,
            networkDisplayName: params.displayName,
            isMainnet: wallet.network.isMainnet,
            send: { address, amount, feeRate in
                // `manager.send` is non-isolated async — broadcast runs off the main actor.
                try await self.manager.send(walletId: id, to: address, amount: amount, feeRate: feeRate)
            },
            onSent: { tx in self.insertPending(tx) })
    }

    /// Optimistically surface a just-broadcast tx (pending, no timestamp → sorts to the top).
    /// The next sync replaces this view with BDK's persisted truth, including the balance.
    private func insertPending(_ tx: WalletTx) {
        transactions = sorted([tx] + transactions.filter { $0.txid != tx.txid })
    }

    /// Switch the active wallet. Clears the previous wallet's on-screen state immediately and
    /// re-syncs the new one (isolated per Golden Rule §5 — nothing carries across).
    func selectWallet(id: String) {
        guard id != selectedWalletId else { return }
        manager.select(id: id)
        resetPerWalletState()
        refresh()
        Task { await sync() }
    }

    /// Rename a wallet's label (app metadata — does NOT survive seed-only recovery; see
    /// docs/accounts-and-labels.md for the future BIP-329 label export).
    func renameWallet(id: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? manager.renameWallet(id: id, to: String(trimmed.prefix(24)))
        refresh()
    }

    /// Remove a wallet — purges its mnemonic, metadata, and chain store (Golden Rule §5).
    /// Callers present the confirmation gate (extra-loud when `!isBackedUp`).
    func removeWallet(id: String) {
        let wasSelected = id == selectedWalletId
        try? manager.removeWallet(id: id)
        if wasSelected { resetPerWalletState() }
        refresh()
        if wasSelected && selectedWalletId != nil {
            Task { await sync() }
        }
    }

    /// Clear state that belongs to the outgoing wallet so it can never bleed into the next
    /// (balance/transactions repopulate from the new wallet's sync; cached-first is a TODO).
    private func resetPerWalletState() {
        balance = .zero
        transactions = []
        syncState = .idle
    }

    /// Wipe ALL wallets (Keychain + JSON store + BDK chain stores) → back to the empty state.
    /// Dev/reset affordance — the iOS Keychain survives app deletion, so this is the reliable wipe.
    func wipeAllWallets() {
        try? manager.removeAllWallets()
        resetPerWalletState()
        refresh()
    }

    // MARK: - Balance & sync

    /// Sync the selected wallet against its network backend, updating `balance` + `syncState`.
    /// The BDK network work runs OFF the main actor (`manager.sync` is a non-isolated async method,
    /// so it runs on the cooperative pool — required, since Android throws on network-on-main); the
    /// observable mutations hop back to the main actor.
    func sync() async {
        guard let id = selectedWalletId else { return }
        syncState = .syncing
        do {
            // `manager.sync` is a non-isolated async method, so the BDK network work runs off the
            // main actor; execution resumes here on the main actor for the observable updates.
            let updated = try await manager.sync(walletId: id)
            balance = updated
            transactions = sorted((try? manager.transactions(walletId: id)) ?? [])
            syncState = .idle
        } catch let error as WalletError {
            syncState = .failed(error.userMessage)
        } catch {
            syncState = .failed("Couldn't sync with the network. Try again.")
        }
    }

    /// Reveal the selected wallet's NEXT receive address (advances + persists the index) — for
    /// the explicit "New address" action. Local derivation only (no network), safe on the main
    /// actor. Returns nil if there's no selected wallet or derivation fails.
    func nextReceiveAddress() -> AddressInfo? {
        guard let id = selectedWalletId else { return nil }
        return try? manager.nextReceiveAddress(walletId: id)
    }

    /// The selected wallet's lowest revealed-but-unused receive address — the Receive screen's
    /// default (doesn't advance on every open; see WalletManager.nextUnusedAddress).
    func nextUnusedAddress() -> AddressInfo? {
        guard let id = selectedWalletId else { return nil }
        return try? manager.nextUnusedAddress(walletId: id)
    }

    /// TEMP (remove): sample transactions to verify the activity-row layout without on-chain funds.
    static let sampleTransactions: [WalletTx] = [
        WalletTx(txid: "sample-pending", netSats: -125000, feeSats: 200,
                 confirmations: 0, timestampEpochSeconds: nil, isRBF: true),
        WalletTx(txid: "sample-recv", netSats: 200_000_000, feeSats: nil,
                 confirmations: 7, timestampEpochSeconds: Int64(1_718_200_000), isRBF: true),
        WalletTx(txid: "sample-sent", netSats: -400_000, feeSats: 180,
                 confirmations: 24, timestampEpochSeconds: Int64(1_718_100_000), isRBF: false),
    ]

    /// Newest first, with unconfirmed (pending) txs at the top. Unconfirmed have no timestamp, so
    /// they sort above everything; confirmed sort by block time descending.
    private func sorted(_ txs: [WalletTx]) -> [WalletTx] {
        txs.sorted { a, b in
            (a.timestampEpochSeconds ?? Int64.max) > (b.timestampEpochSeconds ?? Int64.max)
        }
    }

    private func refresh() {
        wallets = manager.wallets
        selectedWalletId = manager.selectedWalletId
        // Persist the active wallet so it survives cold starts (create/import/select/remove all
        // funnel through here).
        UserDefaults.standard.set(selectedWalletId, forKey: Self.selectedWalletKey)
        // We deliberately do NOT read balance/transactions here. Both require building the BDK engine
        // (open SQLite, derive descriptors), and on a wallet with real chain data that blocks the
        // main thread long enough to ANR on launch (CLAUDE.md §10 — BDK work stays off the main
        // actor). `sync()` populates them off-main; until the first sync they're zero/empty.
    }
}
