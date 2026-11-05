// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Persistence for just the wallet LIST — PUBLIC metadata only (Golden Rule §5):
/// the `ManagedWallet` records (label, network, public/xpub descriptors, backup flag, order).
///
/// We deliberately do NOT store chain data (UTXOs, transactions, derivation state) here — **BDK
/// owns all of that** and persists it itself: each wallet's `WalletEngine` is built with
/// `Persister.newSqlite(path:)`, so BDK manages its own per-wallet SQLite file. This store only
/// tracks the small set of "which wallets exist + their labels/order", so a JSON file is plenty
/// (no SQLite needed on our side).
/// `public` + `// SKIP @nobridge`: `WalletManager` references the protocol and constructs the
/// concrete stores cross-file (needs public for the transpiled Kotlin to resolve them), but the
/// stores aren't part of the bridged surface — the app talks to `WalletManager` only.
// SKIP @nobridge
public protocol WalletStore: AnyObject {
    func allWallets() throws -> [ManagedWallet]
    func upsertWallet(_ wallet: ManagedWallet) throws
    func deleteWallet(id: String) throws
    func deleteAll() throws
    /// Replace the whole list with the seed-container (v2) shape in one write. The migration
    /// applier's commit step (`docs/seed-container-model.md §6`); after it the store is in v2 mode.
    func commitV2(_ wallets: [ManagedWallet]) throws
    /// True once `commitV2` has run. The applier never migrates a v2 store.
    var isV2: Bool { get }
    /// Snapshot the legacy list before anything moves (`wallets.json` → `wallets.json.pre-v2`,
    /// invariant I5). Idempotent; a no-op where there is nothing to snapshot.
    func beginV2Migration() throws
    /// Persist the applier's report (`migration-v2.log.json`): ids, store names and counts only.
    func saveMigrationReport(_ json: Data) throws
}

/// In-memory WalletStore — the working store for now (and for fast unit tests; Robolectric-safe).
// SKIP @nobridge
public final class InMemoryWalletStore: WalletStore {
    private var wallets: [String: ManagedWallet] = [:]

    public init() {}

    public func allWallets() throws -> [ManagedWallet] {
        Array(wallets.values).sorted { $0.sortIndex < $1.sortIndex }
    }

    public func upsertWallet(_ wallet: ManagedWallet) throws {
        wallets[wallet.id] = wallet
    }

    public func deleteWallet(id: String) throws {
        wallets[id] = nil
    }

    public func deleteAll() throws {
        wallets.removeAll()
    }

    public func commitV2(_ list: [ManagedWallet]) throws {
        wallets.removeAll()
        for w in list { wallets[w.id] = w }
        isV2 = true
    }

    public private(set) var isV2 = false
    public private(set) var migrationBegun = false
    public private(set) var migrationReports: [Data] = []
    public func beginV2Migration() throws { migrationBegun = true }
    public func saveMigrationReport(_ json: Data) throws { migrationReports.append(json) }
}

/// The real store: the wallet list as JSON on disk. Cross-platform via SkipFoundation, no SQLite.
/// Small enough that read-modify-write per change is fine.
///
/// **Two files, one mode at a time** (`docs/seed-container-model.md §6.1`):
/// - `wallets.json` — the **legacy** list, one record per (seed × network). Read and written
///   until the seed-container migration has committed.
/// - `wallets.v2.json` — the **container** list (`version: 2`, wallets with accounts). Once it
///   exists the store reads and writes ONLY this file and never touches `wallets.json` again, which
///   stays frozen so a downgrade still boots (§6.4).
/// `commitV2` is the one-way switch; the applier calls it after the file moves have verified.
// SKIP @nobridge
public final class FileWalletStore: WalletStore {
    private let legacyURL: URL
    private let v2URL: URL

    /// `fileURL` is the legacy `wallets.json`; the v2 file sits beside it as `wallets.v2.json`.
    public convenience init(fileURL: URL) {
        self.init(legacyURL: fileURL,
                  v2URL: fileURL.deletingLastPathComponent().appendingPathComponent("wallets.v2.json"))
    }

    public init(legacyURL: URL, v2URL: URL) {
        self.legacyURL = legacyURL
        self.v2URL = v2URL
    }

    /// Default location: `<applicationSupport>/wallets.json` (+ `wallets.v2.json`).
    public static func applicationSupport() throws -> FileWalletStore {
        let dir = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileWalletStore(fileURL: dir.appendingPathComponent("wallets.json"))
    }

    /// True once `commitV2` has run (the v2 file exists). The applier checks this to never migrate twice.
    public var isV2: Bool { FileManager.default.fileExists(atPath: v2URL.path) }
    /// The frozen legacy file — the applier snapshots it to `wallets.json.pre-v2` before committing.
    public var legacyFileURL: URL { legacyURL }
    public var v2FileURL: URL { v2URL }
    /// `wallets.json.pre-v2` — a byte copy of the legacy list taken before the migration moved anything.
    public var preV2SnapshotURL: URL { URL(fileURLWithPath: legacyURL.path + ".pre-v2") }
    /// `migration-v2.log.json` beside the wallet list.
    public var migrationReportURL: URL {
        legacyURL.deletingLastPathComponent().appendingPathComponent("migration-v2.log.json")
    }

    public func beginV2Migration() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path), !fm.fileExists(atPath: preV2SnapshotURL.path) else { return }
        do {
            try fm.copyItem(at: legacyURL, to: preV2SnapshotURL)
        } catch {
            throw WalletError.persistenceFailed
        }
    }

    public func saveMigrationReport(_ json: Data) throws {
        try json.write(to: migrationReportURL)
    }

    // MARK: Legacy DTO (unchanged shape — older builds must keep decoding it)

    /// Codable mirror of a pre-container `ManagedWallet`. `ManagedWallet` itself is NOT `Codable`
    /// (it's bridged to Android and a JNI-peer struct can't synthesize Codable), so we persist
    /// through DTOs. `WalletNetwork` is Codable, so this synthesizes cleanly.
    private struct StoredWallet: Codable {
        let id: String
        let label: String
        let network: WalletNetwork
        let externalDescriptor: String
        let internalDescriptor: String
        /// Optional so records written before this field decode as nil → `.mnemonic` (below),
        /// keeping older `wallets.json` files readable.
        let keyType: WalletKeyType?
        /// Optional (older records → nil → `.bip84`/`0`), so the derivation choice is back-compat.
        let scriptType: ScriptType?
        let accountIndex: Int32?
        let isBackedUp: Bool
        let sortIndex: Int

        /// Only a one-account wallet has a legacy form; the caller checks.
        init(_ w: ManagedWallet) {
            let a = w.selectedAccount
            id = w.id; label = w.label; network = a.network
            externalDescriptor = a.externalDescriptor; internalDescriptor = a.internalDescriptor
            keyType = w.keyType; scriptType = a.scriptType; accountIndex = a.accountIndex
            isBackedUp = w.isBackedUp; sortIndex = w.sortIndex
        }
        var managed: ManagedWallet {
            ManagedWallet(id: id, label: label, network: network,
                          externalDescriptor: externalDescriptor, internalDescriptor: internalDescriptor,
                          keyType: keyType ?? .mnemonic,
                          scriptType: scriptType ?? .bip84, accountIndex: accountIndex ?? 0,
                          isBackedUp: isBackedUp, sortIndex: sortIndex)
        }
    }

    // MARK: v2 DTOs (`{"version": 2, "wallets": [...]}`)
    //
    // Every field a future build might add is decoded leniently (unknown keys are ignored by
    // Codable; new optional keys default), so a v2 file written by a newer app still loads here.

    private struct StoredAccountV2: Codable {
        let id: String
        let network: WalletNetwork
        let scriptType: ScriptType
        let accountIndex: Int32
        let externalDescriptor: String
        let internalDescriptor: String
        let storeName: String

        init(_ a: WalletAccount) {
            id = a.id; network = a.network; scriptType = a.scriptType; accountIndex = a.accountIndex
            externalDescriptor = a.externalDescriptor; internalDescriptor = a.internalDescriptor
            storeName = a.storeName
        }
        var account: WalletAccount {
            WalletAccount(id: id, network: network, scriptType: scriptType, accountIndex: accountIndex,
                          externalDescriptor: externalDescriptor, internalDescriptor: internalDescriptor,
                          storeName: storeName)
        }
    }

    private struct StoredWalletV2: Codable {
        let id: String
        let label: String
        let keyType: WalletKeyType?
        let isBackedUp: Bool
        let sortIndex: Int
        let selectedAccountId: String?
        let accounts: [StoredAccountV2]
        let mergedFrom: [String]?
        let orphanKeychainIds: [String]?

        init(_ w: ManagedWallet) {
            id = w.id; label = w.label; keyType = w.keyType; isBackedUp = w.isBackedUp
            sortIndex = w.sortIndex; selectedAccountId = w.selectedAccountId
            accounts = w.accounts.map { StoredAccountV2($0) }
            mergedFrom = w.mergedFrom; orphanKeychainIds = w.orphanKeychainIds
        }
        /// `nil` for a record with no accounts — unrepresentable, and the applier's `verify` never
        /// writes one. Skipped on load rather than crashing the whole list (the phrase stays in the
        /// Keychain; nothing is deleted).
        var managed: ManagedWallet? {
            let accts = accounts.map { $0.account }
            guard let first = accts.first else { return nil }
            return ManagedWallet(id: id, label: label, keyType: keyType ?? .mnemonic,
                                 isBackedUp: isBackedUp, sortIndex: sortIndex,
                                 selectedAccountId: selectedAccountId ?? first.id, accounts: accts,
                                 mergedFrom: mergedFrom ?? [], orphanKeychainIds: orphanKeychainIds ?? [])
        }
    }

    private struct StoredFileV2: Codable {
        let version: Int
        let wallets: [StoredWalletV2]
    }

    static let v2Version = 2

    // MARK: IO

    private func loadAll() throws -> [ManagedWallet] {
        if isV2 {
            guard let data = try? Data(contentsOf: v2URL) else { return [] }
            let file = (try? JSONDecoder().decode(StoredFileV2.self, from: data))
            return (file?.wallets ?? []).compactMap { $0.managed }
        }
        guard let data = try? Data(contentsOf: legacyURL) else { return [] }
        let stored = (try? JSONDecoder().decode([StoredWallet].self, from: data)) ?? []
        return stored.map { $0.managed }
    }

    private func saveAll(_ wallets: [ManagedWallet]) throws {
        if isV2 {
            try writeV2(wallets)
            return
        }
        // Legacy mode: the legacy file can only hold one-account wallets. A multi-account wallet
        // before the migration has committed is a programming error — refuse rather than silently
        // drop accounts (fail loud, Golden Rule §8).
        for w in wallets where w.accounts.count != 1 {
            throw WalletError.persistenceFailed
        }
        let data = try JSONEncoder().encode(wallets.map { StoredWallet($0) })
        try data.write(to: legacyURL)
    }

    private func writeV2(_ wallets: [ManagedWallet]) throws {
        let file = StoredFileV2(version: FileWalletStore.v2Version, wallets: wallets.map { StoredWalletV2($0) })
        let data = try JSONEncoder().encode(file)
        try data.write(to: v2URL)
    }

    public func allWallets() throws -> [ManagedWallet] {
        try loadAll().sorted { $0.sortIndex < $1.sortIndex }
    }

    public func upsertWallet(_ wallet: ManagedWallet) throws {
        var all = try loadAll()
        all.removeAll { $0.id == wallet.id }
        all.append(wallet)
        try saveAll(all)
    }

    public func deleteWallet(id: String) throws {
        var all = try loadAll()
        all.removeAll { $0.id == id }
        try saveAll(all)
    }

    /// Remove every wallet. In v2 mode this writes an EMPTY v2 list rather than deleting the file:
    /// deleting it would drop the store back into legacy mode and resurrect the frozen
    /// `wallets.json` on the next read.
    public func deleteAll() throws {
        if isV2 {
            try writeV2([])
        } else {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    /// The one-way switch to v2 (see the type comment). Writes the container list; from here on the
    /// legacy file is never read or written again.
    public func commitV2(_ wallets: [ManagedWallet]) throws {
        try writeV2(wallets)
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
