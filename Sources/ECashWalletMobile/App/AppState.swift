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

    /// Routes per-wallet ops to the right engine: `.thunder` wallets → the Fuse-native
    /// `ThunderService`, everything else → the bridged BDK `WalletManager`. Constructed in `init`
    /// once `manager` exists. See docs/thunder-sidechain-support.md.
    private let walletOps: WalletFacade

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

    /// Recovery-phrase length (12 or 24) for NEW wallets. Chosen ONCE in Settings, not per-wallet —
    /// the create flow reads this so creating a wallet stays a single tap. Persisted; default 12
    /// (plenty for most wallets; 24 adds entropy). Anything other than 24 normalizes to 12.
    var newWalletWordCount: Int {
        didSet { UserDefaults.standard.set(newWalletWordCount, forKey: Self.newWalletWordCountKey) }
    }

    private static let selectedWalletKey = "selectedWalletId"
    private static let appLockKey = "appLockEnabled"
    private static let appLockGraceKey = "appLockGraceSeconds"
    private static let newWalletWordCountKey = "newWalletWordCount"

    /// App-lock gate (biometric/passcode on launch + foreground resume). Default ON.
    let appLock: AppLockModel

    /// Fiat pricing: display currency (user setting) + the latest quote. Provider is bundled
    /// per network (`PriceProviderRegistry`); fiat shows only for networks that have one (e.g. mainnet).
    let price = PriceService()

    /// Push-notification client (Phase 1). Registered once the main shell appears (see MainTabView),
    /// which fires the permission prompt + fetches the device token. Used only for manually-sent
    /// broadcast announcements — no backend that knows wallet data (docs/notifications.md).
    let push = PushNotificationService()

    /// Local per-network topic subscriptions (a client-side "follow" preference — CoinNews topics are
    /// per network, so this is keyed by network too).
    let topicSubscriptions = TopicSubscriptionStore()

    /// Optimistic, persisted "just-published" CoinNews (stories + topics) so they appear in the feed
    /// before the indexer catches up (~10 min to mine + index). Per network; shared across feeds.
    let pendingCoinNews = PendingCoinNewsStore()

    /// News tab feed for the **selected wallet's network**. CoinNews is on-chain per network, so the
    /// feed, topics, and follow set all differ by network; we cache one `CoinNewsViewModel` per
    /// network (`coinNewsByNetwork`) and re-point `coinNews` on every wallet/network switch. Each is
    /// long-lived (survives tab switches), like `price`.
    private(set) var coinNews: CoinNewsViewModel
    private var coinNewsByNetwork: [WalletNetwork: CoinNewsViewModel] = [:]
    private var coinNewsNetwork: WalletNetwork?

    /// The selected wallet's CoinNews feed (cached per network). `nil` only with no wallet.
    private func feed(for network: WalletNetwork) -> CoinNewsViewModel {
        if let existing = coinNewsByNetwork[network] { return existing }
        let vm = Self.makeCoinNewsFeed(for: network, pending: pendingCoinNews)
        vm.followed = topicSubscriptions.followed(on: network)
        coinNewsByNetwork[network] = vm
        return vm
    }

    /// Re-point `coinNews` at the selected wallet's network feed (no-op if unchanged). Called after
    /// every state mutation via `refresh()`, so a wallet switch swaps the News tab to that network.
    private func updateCoinNewsFeed() {
        let network = selectedWallet?.network ?? coinNewsNetwork ?? .signet
        guard network != coinNewsNetwork else { return }
        coinNewsNetwork = network
        coinNews = feed(for: network)
    }

    /// Builds the per-network feed.
    ///   1. **Production:** the public `coinnews.v1` indexer for the network (`CoinNewsEndpointRegistry`,
    ///      signet today) via `CoinNewsV1Client` — the real source of stories/topics.
    ///   2. **Dev override (opt-in):** if `COINNEWS_DEV_ENDPOINT` is set, point that ONE network
    ///      (`COINNEWS_DEV_NETWORK`, default `signet`) at a local BitWindow `misc.v1` instead
    ///      (`COINNEWS_DEV_TOKEN` = its `.auth.cookie`). Takes precedence so you can test a local node.
    ///   3. **No indexer for the network:** empty feed (no hardcoded/seeded content).
    private static func makeCoinNewsFeed(for network: WalletNetwork, pending: PendingCoinNewsStore) -> CoinNewsViewModel {
        CoinNewsViewModel(network: network, fetcher: makeCoinNewsFetcher(for: network), pending: pending)
    }

    private static func makeCoinNewsFetcher(for network: WalletNetwork) -> CoinNewsFetching {
        let env = ProcessInfo.processInfo.environment
        // Dev: local BitWindow (misc.v1, auth cookie) for the one network it serves.
        if let endpoint = env["COINNEWS_DEV_ENDPOINT"], let url = URL(string: endpoint),
           network == (WalletNetwork(rawValue: env["COINNEWS_DEV_NETWORK"] ?? "") ?? .signet) {
            return BitWindowCoinNewsClient(endpoint: CoinNewsEndpoint(baseURL: url, bearerToken: env["COINNEWS_DEV_TOKEN"]))
        }
        // Production: the public coinnews.v1 indexer for this network.
        if let endpoint = CoinNewsEndpointRegistry.publicEndpoint(for: network) {
            return CoinNewsV1Client(endpoint: endpoint)
        }
        // No indexer hosted for this network yet.
        return EmptyCoinNewsClient()
    }

    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    init() {
        // The public WalletManager() wires the real Keychain + JSON store + BDK factory internally
        // (those are WalletService implementation details — not part of the bridged surface).
        manager = WalletManager()
        // Route Thunder wallets to the Fuse-native engine; the mnemonic is read app-side, transiently,
        // only when Thunder needs to derive/sign (Golden Rule §2). Everything else stays on BDK.
        walletOps = WalletFacade(
            primary: WalletManagerOps(manager),
            thunder: ThunderService(loadMnemonic: { [manager] id in try manager.mnemonic(for: id) }),
            isThunder: { [manager] id in manager.wallets.first { $0.id == id }?.network == .thunder })
        balanceHidden = UserDefaults.standard.bool(forKey: "balanceHidden")
        // New-wallet seed length: 24 if explicitly chosen, otherwise 12 (covers unset → default 12).
        newWalletWordCount = (UserDefaults.standard.object(forKey: Self.newWalletWordCountKey) as? Int) == 24 ? 24 : 12
        try? manager.load()
        // Restore the active wallet across launches (manager.load defaults to the first wallet;
        // select is a no-op if the saved id no longer exists).
        if let saved = UserDefaults.standard.string(forKey: Self.selectedWalletKey) {
            manager.select(id: saved)
        }
        // Point the News feed at the selected wallet's network up front (CoinNews is per network).
        // Build it via a direct member assignment now (a stored prop with no default must be set
        // before `self` is fully initialized); the cache + `updateCoinNewsFeed()` are populated
        // below, once every stored property exists.
        let selectedId = manager.selectedWalletId
        let initialNetwork = manager.wallets.first { $0.id == selectedId }?.network ?? .signet
        let initialFeed = Self.makeCoinNewsFeed(for: initialNetwork, pending: pendingCoinNews)
        initialFeed.followed = topicSubscriptions.followed(on: initialNetwork)
        coinNews = initialFeed
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
        // Now that all stored properties exist, register the initial feed in the per-network cache
        // (subscript mutation needs a fully-initialized `self`). `updateCoinNewsFeed()` is a no-op
        // for this network until the user switches to a wallet on a different one.
        coinNewsByNetwork[initialNetwork] = initialFeed
        coinNewsNetwork = initialNetwork
        refresh()
        // Best-effort: pull the latest backend endpoints and apply them over the bundled defaults.
        // Fire-and-forget — a failure leaves last-known-good/bundled endpoints untouched (never
        // blocks launch). Runs after the initial `load()`, so a changed endpoint evicts engines and
        // the next `sync()` picks it up.
        Task { await refreshRemoteEndpoints() }
    }

    /// Fetch the remote endpoints config and apply each per-network backend into the manager. Purely
    /// additive over the bundled defaults, and fail-safe (see `RemoteEndpointConfigService`). The
    /// off-actor fetch returns a plain value; the apply runs here on the main actor.
    func refreshRemoteEndpoints(force: Bool = false) async {
        // Throttle: skip if a fetch isn't due yet (honors the payload's refresh_after_seconds). The
        // app calls this on launch AND every foreground resume, so this keeps frequent resumes cheap.
        guard force || RemoteConfigRefreshPolicy.isDue() else { return }
        guard let config = await RemoteEndpointConfigService().load() else { return }
        RemoteConfigRefreshPolicy.recordFetch(interval: config.refreshAfterSeconds)
        // Backends → WalletManager (user Settings override still wins; see resolvedBackend).
        for backend in config.resolvedPrimaryBackends() {
            manager.setRemoteBackendDefault(network: backend.network, kind: backend.kind, url: backend.url)
        }
        // Services → the app-side overlay the registries read (dev-env override still wins for CoinNews).
        var coinNewsChanged = false
        for cn in config.resolvedCoinNews() {
            if RemoteServiceOverrides.setCoinNewsURL(cn.url, for: cn.network) { coinNewsChanged = true }
        }
        for f in config.resolvedFaucets() {
            RemoteServiceOverrides.setFaucet(url: f.url, amount: f.amount,
                                             cooldownSeconds: f.cooldownSeconds, for: f.network)
        }
        for e in config.resolvedExplorers() {
            RemoteServiceOverrides.setExplorerTemplate(e.txTemplate, for: e.network)
        }
        // A new/changed CoinNews endpoint means the cached feed for that network is stale — drop it so
        // it rebuilds against the new indexer, and re-point the visible feed if it's the current one.
        if coinNewsChanged {
            coinNewsByNetwork.removeAll()
            if let network = selectedWallet?.network ?? coinNewsNetwork {
                coinNews = feed(for: network)
            }
        }
        // Recompute derived capability flags (faucetAvailable / coinNewsAvailable → tab visibility).
        refresh()
        // If a wallet is showing, re-sync in case the winning backend changed (engines are evicted
        // only on an actual change, so this is a no-op when the config matched what we already had).
        if manager.selectedWalletId != nil {
            await sync()
        }
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

    /// Whether the News (CoinNews) tab is offered for the selected wallet's network. Code-level
    /// capability (see `CoinNewsAvailability`) — off on Bitcoin mainnet. Drives tab visibility.
    var coinNewsAvailable: Bool {
        guard let network = selectedWallet?.network else { return false }
        return CoinNewsAvailability.isAvailable(on: network)
    }

    /// Whether to offer the "Get coins" faucet for the selected wallet's network. Code-level
    /// capability (`FaucetRegistry`) — signet only, valueless test coins. Drives the home button.
    var faucetAvailable: Bool {
        guard let network = selectedWallet?.network else { return false }
        return FaucetRegistry.isAvailable(on: network)
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

    /// Import a legacy **WIF private key** as a single-key wallet (Advanced import). Throws
    /// `WalletError.invalidPrivateKey` on a bad key — never echoes the input (`docs/wif-import-and-sweep.md`).
    @discardableResult
    func importPrivateKey(label: String, network: WalletNetwork, wif: String) throws -> ManagedWallet {
        let wallet = try manager.importPrivateKey(label: label, network: network, wif: wif)
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

    /// Vend an `ImportViewModel` wired to this manager (used by the Import flow) — recovery-phrase
    /// import, plus the Advanced legacy-WIF path and its live address preview.
    func makeImportViewModel() -> ImportViewModel {
        ImportViewModel(
            importWallet: { label, network, mnemonic in
                _ = try self.importWallet(label: label, network: network, mnemonic: mnemonic)
            },
            importPrivateKey: { label, network, wif in
                _ = try self.importPrivateKey(label: label, network: network, wif: wif)
            },
            previewWIF: { wif, network in
                // Best-effort: nil on an invalid key (no error surfaced mid-typing).
                try? self.manager.previewAddress(forWIF: wif, network: network)
            })
    }

    /// Vend a `BackupViewModel` for the selected wallet, or nil if none is selected. The wallet
    /// id is captured at presentation time (same rule as Send — a switch mid-flow can't
    /// redirect which wallet's phrase is shown or marked backed up).
    func makeBackupViewModel() -> BackupViewModel? {
        guard let id = selectedWalletId else { return nil }
        return BackupViewModel(
            walletLabel: selectedWallet?.label ?? "",
            keyType: selectedWallet?.keyType ?? .mnemonic,
            loadMnemonic: { try self.manager.mnemonic(for: id) },
            markBackedUp: {
                try self.manager.setBackedUp(id: id)
                self.refresh()   // flips `isBackedUp` → the Home warning disappears
            },
            authenticate: { reason in await DeviceAuth.authenticate(reason: reason) })
    }

    /// The in-flight Send flow's view model, cached on `AppState` (which is owned by `RootView` and
    /// never torn down). `makeSendViewModel()` returns this SAME instance across SwiftUI re-renders
    /// AND a full cover/SendScreen recreation — which the biometric prompt's scene-phase change
    /// triggers on the first send after a cold launch. Without the cache, the recreation handed
    /// SendScreen a brand-new VM stuck at the address step while the ORIGINAL VM's broadcast Task
    /// finished off-screen, so a successful send landed the user back on the address screen.
    /// `beginSendFlow()` clears it at each Send tap so a fresh flow never reuses a finished one.
    @ObservationIgnored private var activeSendVM: SendViewModel?

    /// Discard any cached Send VM so the next `makeSendViewModel()` builds a fresh flow. Call when
    /// the user opens Send (before presenting the cover).
    func beginSendFlow() { activeSendVM = nil }

    /// Vend a `SendViewModel` for the selected wallet, or nil if none is selected. Returns the
    /// cached in-flight instance if one exists (survives recreation); otherwise builds + caches one.
    /// Captures the wallet id at presentation time so a wallet switch mid-flow can't redirect the send.
    func makeSendViewModel() -> SendViewModel? {
        if let activeSendVM { return activeSendVM }
        guard let id = selectedWalletId, let wallet = selectedWallet else { return nil }
        let params = NetworkRegistry.params(for: wallet.network)
        let vm = SendViewModel(
            balance: balance,
            unitLabel: params.unitLabel,
            network: wallet.network,
            send: { address, amount, feeRate in
                // Routed via the facade: BDK wallets broadcast off the main actor as before; a Thunder
                // wallet gets `.backendUnavailable` until its RPC is wired.
                try await self.walletOps.send(walletId: id, to: address, amount: amount, feeRate: feeRate)
            },
            onSent: { tx in self.insertPending(tx) },
            authorize: { reason in
                // Require device auth before sending when app-lock is on (§7); pass through if off.
                guard self.appLock.enabled else { return true }
                return await DeviceAuth.authenticate(reason: reason)
            },
            // Validate the recipient against THIS wallet's network (checksum + prefix), up front.
            validateAddress: { address in
                // Thunder addresses are BLAKE3/base58, not BDK — validate them app-side; BDK would
                // reject every one. (The send itself still errors with `.backendUnavailable` until the
                // Thunder RPC lands.)
                wallet.network == .thunder
                    ? ThunderAddress(base58: address) != nil
                    : self.manager.isValidAddress(address, network: wallet.network)
            })
        activeSendVM = vm
        return vm
    }

    /// Vend a `PostStoryViewModel` for the selected wallet (CoinNews "post news"), or nil if none.
    /// Topics come from the News feed's fetched list (`ListTopics`).
    func makePostStoryViewModel() -> PostStoryViewModel? {
        guard let id = selectedWalletId, let wallet = selectedWallet else { return nil }
        let params = NetworkRegistry.params(for: wallet.network)
        return PostStoryViewModel(
            network: wallet.network,
            unitLabel: params.unitLabel,
            availableTopics: coinNews.topics,
            publish: { payloadHex, feeRate in
                try await self.manager.publishOpReturn(walletId: id, payloadHex: payloadHex, feeRate: feeRate)
            },
            onPublished: { item, tx in
                self.insertPending(tx)                 // pending tx → Activity
                self.coinNews.addPendingStory(item)    // optimistic story → News feed until indexed
            },
            fiatString: { sats in self.fiatString(forSats: sats) },
            authorize: { reason in
                // Require device auth before publishing when app-lock is on (§7); pass through if off.
                guard self.appLock.enabled else { return true }
                return await DeviceAuth.authenticate(reason: reason)
            })
    }

    /// Vend a `CreateTopicViewModel` (CoinNews Topic Creation §5). `onCreated` hands back the new
    /// topic so the presenter can react (select it while composing, or optimistically list + follow
    /// it in the manager). The new topic is also optimistically added to the current network's feed.
    func makeCreateTopicViewModel(onCreated: @escaping @MainActor (CoinNewsTopic) -> Void) -> CreateTopicViewModel? {
        guard let id = selectedWalletId, let wallet = selectedWallet else { return nil }
        let params = NetworkRegistry.params(for: wallet.network)
        return CreateTopicViewModel(
            network: wallet.network,
            unitLabel: params.unitLabel,
            publish: { payloadHex, feeRate in
                try await self.manager.publishOpReturn(walletId: id, payloadHex: payloadHex, feeRate: feeRate)
            },
            onCreated: { topic, tx in
                self.insertPending(tx)
                self.coinNews.addPendingTopic(topic)   // persisted optimistic topic until indexed
                onCreated(topic)
            },
            fiatString: { sats in self.fiatString(forSats: sats) },
            authorize: { reason in
                guard self.appLock.enabled else { return true }
                return await DeviceAuth.authenticate(reason: reason)
            })
    }

    /// Vend a `TopicsViewModel` for the selected wallet's network (the topic manager). Browses topics
    /// from the network's feed, follows/unfollows via the per-network subscription store, and applies
    /// the feed filter. `nil` with no selected wallet.
    func makeTopicsViewModel() -> TopicsViewModel? {
        guard selectedWallet != nil else { return nil }
        return TopicsViewModel(
            feed: coinNews,
            subscriptions: topicSubscriptions,
            makeCreateTopic: { onCreated in self.makeCreateTopicViewModel(onCreated: onCreated) })
    }

    /// Vend a `CoinNewsDetailViewModel` for a story (the detail page): loads its thread, casts votes,
    /// posts comments. Votes/comments are signed on-chain txs with a default fee, bio-gated like
    /// publishing. `nil` with no selected wallet.
    func makeCoinNewsDetailViewModel(item: CoinNewsItem) -> CoinNewsDetailViewModel? {
        guard let id = selectedWalletId, let wallet = selectedWallet else { return nil }
        let params = NetworkRegistry.params(for: wallet.network)
        let defaultFee = FeeRate(satPerVByte: 2)   // "Normal" — votes/comments are small txs
        return CoinNewsDetailViewModel(
            item: item,
            network: wallet.network,
            unitLabel: params.unitLabel,
            fetchItem: { itemId in try await self.coinNews.item(id: itemId) },
            fetchThread: { rootId in try await self.coinNews.thread(rootId: rootId) },
            vote: { targetIdHex, up in
                let tx = try await self.manager.publishVote(walletId: id, targetIdHex: targetIdHex, upvote: up, feeRate: defaultFee)
                self.insertPending(tx)   // show the vote tx in Activity immediately (CoinNews vote)
                return tx
            },
            comment: { parentIdHex, body in
                let tx = try await self.manager.publishComment(walletId: id, parentIdHex: parentIdHex, body: body, feeRate: defaultFee)
                self.insertPending(tx)   // show the comment tx in Activity immediately
                return tx
            },
            pending: pendingCoinNews,
            authorize: { reason in
                guard self.appLock.enabled else { return true }
                return await DeviceAuth.authenticate(reason: reason)
            })
    }

    /// Vend a `FaucetViewModel` for the selected wallet (signet faucet — valueless test coins), or
    /// nil if the network has no faucet (`FaucetRegistry`) or no receive address is available. The
    /// destination is the wallet's next unused receive address; on success it re-syncs so the incoming
    /// coins surface. The network call runs off-main via the nonisolated `FaucetClient`.
    func makeFaucetViewModel() -> FaucetViewModel? {
        guard let wallet = selectedWallet,
              let config = FaucetRegistry.config(for: wallet.network),
              let addr = nextUnusedAddress() else { return nil }
        let network = wallet.network
        let params = NetworkRegistry.params(for: network)
        let client = FaucetClient(endpoint: config.endpoint)
        return FaucetViewModel(
            address: addr.address,
            unitLabel: params.unitLabel,
            amount: config.amount,
            cooldownRemaining: faucetCooldownRemaining(for: network, cooldown: config.cooldown),
            dispense: { destination, amount in try await client.dispense(to: destination, amount: amount) },
            onSuccess: {
                self.recordFaucetSuccess(for: network)   // start the client-side cooldown
                Task { await self.sync() }               // pull the incoming coins in
            })
    }

    /// Client-side faucet cooldown (a UX guard on top of the server's own rate limit). Persists the
    /// last successful dispense time per network so a kill/restart doesn't reset it.
    private static func faucetLastSuccessKey(_ network: WalletNetwork) -> String {
        "faucetLastSuccess_\(network.rawValue)"
    }

    private func faucetCooldownRemaining(for network: WalletNetwork, cooldown: TimeInterval) -> TimeInterval {
        let last = UserDefaults.standard.double(forKey: Self.faucetLastSuccessKey(network))
        guard last > 0 else { return 0 }
        return max(0, cooldown - (Date().timeIntervalSince1970 - last))
    }

    private func recordFaucetSuccess(for network: WalletNetwork) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.faucetLastSuccessKey(network))
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
            let updated = try await walletOps.sync(walletId: id)
            balance = updated
            pendingBalance = (try? walletOps.pendingBalance(walletId: id)) ?? .zero
            transactions = sorted((try? walletOps.transactions(walletId: id)) ?? [])
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
        return try? walletOps.nextReceiveAddress(walletId: id)
    }

    /// The selected wallet's lowest revealed-but-unused receive address — the Receive screen's
    /// default (doesn't advance on every open; see WalletManager.nextUnusedAddress).
    func nextUnusedAddress() -> AddressInfo? {
        guard let id = selectedWalletId else { return nil }
        return try? walletOps.nextUnusedAddress(walletId: id)
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
        // Swap the News feed to the (now) selected wallet's network — no-op if the network is the
        // same (e.g. switching between two testnet wallets keeps the same feed).
        updateCoinNewsFeed()
        // We deliberately do NOT read balance/transactions here. Both require building the BDK engine
        // (open SQLite, derive descriptors), and on a wallet with real chain data that blocks the
        // main thread long enough to ANR on launch (CLAUDE.md §10 — BDK work stays off the main
        // actor). `sync()` populates them off-main; until the first sync they're zero/empty.
    }
}
