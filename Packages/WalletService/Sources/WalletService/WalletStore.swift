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
}

/// The real store: the wallet list as a JSON file (Codable `[ManagedWallet]`). Cross-platform via
/// SkipFoundation, no SQLite. Small enough that read-modify-write per change is fine.
// SKIP @nobridge
public final class FileWalletStore: WalletStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: `<applicationSupport>/wallets.json`.
    public static func applicationSupport() throws -> FileWalletStore {
        let dir = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileWalletStore(fileURL: dir.appendingPathComponent("wallets.json"))
    }

    /// Codable mirror of `ManagedWallet`. `ManagedWallet` itself is NOT `Codable` (it's bridged to
    /// Android and a JNI-peer struct can't synthesize Codable — see Models.swift), so we persist
    /// through this private DTO. `WalletNetwork` is Codable, so this synthesizes cleanly.
    private struct StoredWallet: Codable {
        let id: String
        let label: String
        let network: WalletNetwork
        let externalDescriptor: String
        let internalDescriptor: String
        /// Optional so records written before this field decode as nil → `.mnemonic` (below),
        /// keeping older `wallets.json` files readable.
        let keyType: WalletKeyType?
        let isBackedUp: Bool
        let sortIndex: Int

        init(_ w: ManagedWallet) {
            id = w.id; label = w.label; network = w.network
            externalDescriptor = w.externalDescriptor; internalDescriptor = w.internalDescriptor
            keyType = w.keyType; isBackedUp = w.isBackedUp; sortIndex = w.sortIndex
        }
        var managed: ManagedWallet {
            ManagedWallet(id: id, label: label, network: network,
                          externalDescriptor: externalDescriptor, internalDescriptor: internalDescriptor,
                          keyType: keyType ?? .mnemonic, isBackedUp: isBackedUp, sortIndex: sortIndex)
        }
    }

    private func loadAll() throws -> [ManagedWallet] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let stored = (try? JSONDecoder().decode([StoredWallet].self, from: data)) ?? []
        return stored.map { $0.managed }
    }

    private func saveAll(_ wallets: [ManagedWallet]) throws {
        let data = try JSONEncoder().encode(wallets.map { StoredWallet($0) })
        try data.write(to: fileURL)
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

    public func deleteAll() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
