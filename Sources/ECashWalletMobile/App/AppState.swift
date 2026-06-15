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

    /// The selected wallet's SPENDABLE balance (confirmed + own unconfirmed change), refreshed by `sync()`.
    private(set) var balance: Amount = .zero
    /// Not-yet-spendable balance (incoming 0-conf + immature). Shown separately so it doesn't look lost.
    private(set) var pendingBalance: Amount = .zero
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
    private static let appLockKey = "appLockEnabled"
    private static let appLockGraceKey = "appLockGraceSeconds"

    /// App-lock gate (biometric/passcode on launch + foreground resume). Default ON.
    let appLock: AppLockModel

    /// Fiat pricing: display currency (user setting) + the latest quote. Provider is bundled
    /// per network (`PriceProviderRegistry`); fiat shows only for networks that have one (e.g. mainnet).
    let price = PriceService()

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
        // App-lock: default ON. Lock at launch only when armed AND there's a wallet to protect
        // (a fresh install with no wallet is never gated). `object(forKey:) as? Bool` so an unset
        // default reads as ON rather than `bool(forKey:)`'s false.
        let lockEnabled = UserDefaults.standard.object(forKey: Self.appLockKey) as? Bool ?? true
        // Background grace before re-lock; default 10s (unset → 10, not `integer(forKey:)`'s 0).
        let grace = UserDefaults.standard.object(forKey: Self.appLockGraceKey) as? Int ?? 10
        appLock = AppLockModel(
            enabled: lockEnabled,
            startLocked: lockEnabled && manager.hasWallets,
            graceSeconds: grace,
            authenticate: { reason in await DeviceAuth.authenticate(reason: reason) },
            persist: { UserDefaults.standard.set($0, forKey: Self.appLockKey) },
            persistGrace: { UserDefaults.standard.set($0, forKey: Self.appLockGraceKey) })
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
        Array(transactions.prefix(10))
    }

    /// Display unit label (sBTC / tBTC / BTC) for the selected wallet's network.
    var unitLabel: String {
        guard let network = selectedWallet?.network else { return "" }
        return NetworkRegistry.params(for: network).unitLabel
    }

    // MARK: - Mutations (mirror back after each)

    /// Create a new wallet on `network`, persist it, select it. Throws `WalletError` on failure.
    @discardableResult
    func createWallet(label: String, network: WalletNetwork, wordCount: Int = 12) throws -> ManagedWallet {
        let wallet = try manager.createWallet(label: label, network: network, wordCount: wordCount)
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
        CreateViewModel(create: { label, network, wordCount in
            _ = try self.createWallet(label: label, network: network, wordCount: wordCount)
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
            network: wallet.network,
            send: { address, amount, feeRate in
                // `manager.send` is non-isolated async — broadcast runs off the main actor.
                try await self.manager.send(walletId: id, to: address, amount: amount, feeRate: feeRate)
            },
            onSent: { tx in self.insertPending(tx) },
            authorize: { reason in
                // Require device auth before sending when app-lock is on (§7); pass through if off.
                guard self.appLock.enabled else { return true }
                return await DeviceAuth.authenticate(reason: reason)
            },
            // Validate the recipient against THIS wallet's network (checksum + prefix), up front.
            validateAddress: { address in self.manager.isValidAddress(address, network: wallet.network) })
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
        pendingBalance = .zero
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
            pendingBalance = (try? manager.pendingBalance(walletId: id)) ?? .zero
            transactions = sorted((try? manager.transactions(walletId: id)) ?? [])
            syncState = .idle
            // Refresh fiat alongside the balance (no-op for networks without a price provider).
            Task { await refreshPrice() }
        } catch let error as WalletError {
            // We're in a sync: surface a sync/connection-framed message. Specific, actionable
            // errors (e.g. a network mismatch) keep their own text; the generic catch-all
            // (`.engine`) is far more useful framed as a sync failure than "something went wrong".
            switch error {
            case .engine, .persistenceFailed:
                syncState = .failed(WalletError.syncFailed.userMessage)
            default:
                syncState = .failed(error.userMessage)
            }
        } catch {
            syncState = .failed(WalletError.syncFailed.userMessage)
        }
    }

    // MARK: - Fiat pricing

    /// The display currency (Settings → Display currency). Setting it refetches for the selected network.
    var fiatCurrency: FiatCurrency {
        get { price.currency }
        set {
            price.currency = newValue
            Task { await refreshPrice() }
        }
    }

    /// Fetch the price for the selected wallet's network (no-op / clears for networks without a provider).
    func refreshPrice() async {
        guard let network = selectedWallet?.network else { return }
        await price.refresh(for: network)
    }

    /// A fiat string for `sats` in the selected wallet's network, or `nil` when that network has no
    /// price provider (testnets) or no quote yet. Guards against a stale quote across a network switch.
    func fiatString(forSats sats: Int64) -> String? {
        guard let network = selectedWallet?.network,
              PriceProviderRegistry.supportsPricing(network) else { return nil }
        return price.fiatString(forSats: sats)
    }

    // MARK: - Chain backend / custom endpoints (Settings → Network)

    func backendKind(for network: WalletNetwork) -> String { manager.backendKind(for: network) }
    func backendURL(for network: WalletNetwork) -> String { manager.backendURL(for: network) }
    func defaultBackendURL(for network: WalletNetwork) -> String { manager.defaultBackendURL(for: network) }
    func hasBackendOverride(for network: WalletNetwork) -> Bool { manager.hasBackendOverride(for: network) }
    var proxy: String? { manager.proxyValue() }

    // Persist + evict the cached engine. The caller re-syncs once (via `sync()`) so a save that
    // changes both endpoint and proxy doesn't kick off overlapping syncs.
    func setBackend(network: WalletNetwork, kind: String, url: String) {
        manager.setBackendOverride(network: network, kind: kind, url: url)
    }
    func resetBackend(for network: WalletNetwork) {
        manager.clearBackendOverride(network: network)
    }
    func setProxy(_ socks5: String?) {
        manager.setProxy(socks5)
    }

    /// Validate a candidate endpoint before saving — true if the client connects + fetches the tip.
    func testBackend(kind: String, url: String, socks5: String?) async -> Bool {
        do { try await manager.testBackend(kind: kind, url: url, socks5: socks5); return true }
        catch { return false }
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
                 confirmations: 0, timestampEpochSeconds: nil, isRBF: true,
                 blockHeight: nil, vsize: 141),
        WalletTx(txid: "sample-recv", netSats: 200_000_000, feeSats: nil,
                 confirmations: 7, timestampEpochSeconds: Int64(1_718_200_000), isRBF: true,
                 blockHeight: 196_842, vsize: 222),
        WalletTx(txid: "sample-sent", netSats: -400_000, feeSats: 180,
                 confirmations: 24, timestampEpochSeconds: Int64(1_718_100_000), isRBF: false,
                 blockHeight: 196_825, vsize: 110),
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
