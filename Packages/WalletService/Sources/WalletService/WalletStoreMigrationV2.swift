// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

// MARK: - Seed-container migration: the PLANNER (pure)
//
// Step 1 of `docs/seed-container-model.md §11`. Turns today's one-record-per-(seed × network)
// wallet list into the container shape: one wallet per seed, one account per (network, scriptType,
// accountIndex). This file only PLANS — it takes the legacy records and the names of the files in
// the chain-data directory, and returns what the applier should do. It has no BDK, no filesystem,
// and no `KeyStore` reference on purpose (fund-safety invariant I1: the migration never writes or
// deletes a Keychain entry), so it is unit-tested exhaustively away from everything that can lose
// money.
//
// Rules (doc §6.2):
// - Only HD mnemonic records whose persisted public descriptor carries a key origin can merge, and
//   only with records that share the SAME master fingerprint. WIF (no origin) and Thunder (no
//   descriptor) records never merge — they become standalone wallets with one account.
// - The primary of a group is the record with the lowest `sortIndex` (ties: smallest id). Its id,
//   label and store file survive untouched; every other record becomes one of its accounts and its
//   store is moved to the account's name.
// - Anything the planner cannot place safely (two records on the same account, a destination file
//   that already exists) stays a standalone wallet — never dropped, never guessed (I2, I3).
// - Every legacy record ends up as exactly one account somewhere (`verify`).
//
// The plan is made of the real `ManagedWallet` (container) + `WalletAccount` model (step 2), so the
// applier persists exactly what the planner verified. Only the plan/move/rekey wrappers are
// planner-local and stay `internal` (not bridged).

/// A chain-data file rename, basenames within the chain-data directory.
struct PlannedFileMove: Equatable {
    let from: String
    let to: String
}

/// A per-`walletId` app store (e.g. `SplitCheckStore`) whose key must follow a merged record.
struct PlannedRekey: Equatable {
    let legacyId: String
    let walletId: String
    let accountId: String
}

struct MigrationPlan: Equatable {
    let wallets: [ManagedWallet]
    let fileMoves: [PlannedFileMove]
    let rekeys: [PlannedRekey]
    /// The wallet to select after migration — the legacy selection, or the wallet it was merged
    /// into. `nil` when the legacy selection is unknown (the manager falls back to the first).
    let selectedWalletId: String?
    /// Legacy ids that matched a group but were kept standalone because placing them was not
    /// provably safe (account already taken, destination file exists). Surfaced in the report.
    let keptStandalone: [String]

    /// Counts and ids only — never a label or a descriptor (Golden Rule §2 scrubbing; the test
    /// `testSummaryNeverContainsLabelsOrDescriptors` pins it).
    var summary: String {
        let merged = wallets.filter { !$0.mergedFrom.isEmpty }.count
        let accounts = wallets.reduce(0) { $0 + $1.accounts.count }
        var s = "wallets=\(wallets.count) accounts=\(accounts) merged=\(merged) moves=\(fileMoves.count) rekeys=\(rekeys.count)"
        if !keptStandalone.isEmpty {
            s += " keptStandalone=\(keptStandalone.joined(separator: ","))"
        }
        s += " selected=\(selectedWalletId ?? "none")"
        return s
    }

    /// Invariant I2 (and the structural rules the applier relies on). Returns the violations;
    /// empty means the plan is safe to apply. The applier refuses a plan with any violation.
    func verify(against legacy: [ManagedWallet]) -> [String] {
        var problems: [String] = []
        // Every legacy id is exactly one wallet or exactly one merged member, and every input
        // account is carried over exactly once.
        var placed: [String: Int] = [:]
        var accountTotal = 0
        var walletIds = Set<String>()
        var storeNames = Set<String>()
        for w in wallets {
            if walletIds.contains(w.id) { problems.append("duplicate wallet id \(w.id)") }
            walletIds.insert(w.id)
            placed[w.id] = (placed[w.id] ?? 0) + 1
            for m in w.mergedFrom { placed[m] = (placed[m] ?? 0) + 1 }
            if w.accounts.isEmpty { problems.append("wallet \(w.id) has no accounts") }
            var accountIds = Set<String>()
            for a in w.accounts {
                if accountIds.contains(a.id) { problems.append("wallet \(w.id) repeats account \(a.id)") }
                accountIds.insert(a.id)
                if storeNames.contains(a.storeName) { problems.append("store \(a.storeName) used twice") }
                storeNames.insert(a.storeName)
            }
            if !accountIds.contains(w.selectedAccountId) {
                problems.append("wallet \(w.id) selects unknown account \(w.selectedAccountId)")
            }
            accountTotal += w.accounts.count
        }
        for record in legacy {
            let n = placed[record.id] ?? 0
            if n != 1 { problems.append("legacy \(record.id) placed \(n) times") }
        }
        // Every input account survives: a legacy record contributes one, an already-container-shaped
        // record contributes all of its own.
        let inputAccounts = legacy.reduce(0) { $0 + $1.accounts.count }
        if accountTotal != inputAccounts {
            problems.append("accounts \(accountTotal) != input accounts \(inputAccounts)")
        }
        // Moves: distinct destinations, never onto a source, never a no-op.
        var destinations = Set<String>()
        let sources = Set(fileMoves.map { $0.from })
        for m in fileMoves {
            if m.from == m.to { problems.append("no-op move \(m.from)") }
            if destinations.contains(m.to) { problems.append("two moves to \(m.to)") }
            destinations.insert(m.to)
            if sources.contains(m.to) { problems.append("move onto a source \(m.to)") }
        }
        if let sel = selectedWalletId, !walletIds.contains(sel) {
            problems.append("selected wallet \(sel) not in plan")
        }
        return problems
    }
}

enum WalletStoreMigrationV2 {
    /// Whether a legacy record may merge with others of the same seed. Only a single-account HD
    /// mnemonic record on a BDK network with a parseable master fingerprint qualifies; WIF, Thunder,
    /// and anything already in container shape never do.
    static func mergeKey(for record: ManagedWallet) -> String? {
        guard record.accounts.count == 1, record.keyType == .mnemonic, record.network != .thunder else {
            return nil
        }
        return record.masterFingerprint
    }

    static func plan(legacy: [ManagedWallet], chainDataFiles: [String], selectedId: String?) -> MigrationPlan {
        let files = Set(chainDataFiles)
        // Deterministic regardless of input order: lowest sortIndex first, then id.
        let ordered = legacy.sorted { a, b in
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            return a.id < b.id
        }

        // Group by merge key, remembering first-appearance order of the groups.
        var groupOrder: [String] = []
        var groups: [String: [ManagedWallet]] = [:]
        var units: [PlanUnit] = []   // (group key | standalone record), in order of first appearance
        for record in ordered {
            if let key = mergeKey(for: record) {
                if groups[key] == nil {
                    groupOrder.append(key)
                    units.append(PlanUnit(groupKey: key, standalone: nil))
                }
                var members = groups[key] ?? []
                members.append(record)
                groups[key] = members
            } else {
                units.append(PlanUnit(groupKey: nil, standalone: record))
            }
        }

        var wallets: [ManagedWallet] = []
        var moves: [PlannedFileMove] = []
        var rekeys: [PlannedRekey] = []
        var keptStandalone: [String] = []
        var mergedInto: [String: String] = [:]   // secondary id → primary id
        var claimedDestinations = Set<String>()

        for unit in units {
            if let record = unit.standalone {
                wallets.append(standaloneWallet(record))
                continue
            }
            guard let key = unit.groupKey, let members = groups[key], let primary = members.first else { continue }
            if members.count == 1 {
                wallets.append(standaloneWallet(primary))
                continue
            }

            let primaryAccount = primary.selectedAccount   // keeps the store file it already has
            var accounts: [WalletAccount] = [primaryAccount]
            var takenAccountIds = Set<String>([primaryAccount.id])
            var mergedFrom: [String] = []
            var backedUp = primary.isBackedUp
            var selectedAccountId = primaryAccount.id

            for secondary in members.dropFirst() {
                let accountId = WalletAccount.accountId(network: secondary.network,
                                                        scriptType: secondary.scriptType,
                                                        accountIndex: secondary.accountIndex)
                let destination = WalletAccount.storeName(walletId: primary.id, network: secondary.network,
                                                          scriptType: secondary.scriptType,
                                                          accountIndex: secondary.accountIndex)
                let destinationExists = files.contains { $0.hasPrefix(destination) }
                if takenAccountIds.contains(accountId) || destinationExists || claimedDestinations.contains(destination) {
                    // Not provably safe to fold in — keep it as its own wallet, untouched (I2/I3).
                    keptStandalone.append(secondary.id)
                    wallets.append(standaloneWallet(secondary))
                    continue
                }
                takenAccountIds.insert(accountId)
                claimedDestinations.insert(destination)
                accounts.append(WalletAccount(id: accountId, network: secondary.network,
                                              scriptType: secondary.scriptType,
                                              accountIndex: secondary.accountIndex,
                                              externalDescriptor: secondary.externalDescriptor,
                                              internalDescriptor: secondary.internalDescriptor,
                                              storeName: destination))
                moves.append(contentsOf: storeMoves(for: secondary, to: destination, files: files))
                rekeys.append(PlannedRekey(legacyId: secondary.id, walletId: primary.id, accountId: accountId))
                mergedFrom.append(secondary.id)
                mergedInto[secondary.id] = primary.id
                if secondary.isBackedUp { backedUp = true }
                if secondary.id == selectedId { selectedAccountId = accountId }
            }

            wallets.append(ManagedWallet(id: primary.id, label: primary.label, keyType: primary.keyType,
                                         isBackedUp: backedUp, sortIndex: primary.sortIndex,
                                         selectedAccountId: selectedAccountId, accounts: accounts,
                                         mergedFrom: mergedFrom, orphanKeychainIds: mergedFrom))
        }

        // Selection: the legacy selection, or the wallet it was merged into.
        var selectedWalletId: String? = nil
        if let sel = selectedId {
            if wallets.contains(where: { $0.id == sel }) {
                selectedWalletId = sel
            } else if let primary = mergedInto[sel] {
                selectedWalletId = primary
            }
        }

        let sortedWallets = wallets.sorted { a, b in
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            return a.id < b.id
        }
        return MigrationPlan(wallets: sortedWallets, fileMoves: moves, rekeys: rekeys,
                             selectedWalletId: selectedWalletId, keptStandalone: keptStandalone)
    }

    // MARK: - Helpers

    private struct PlanUnit {
        let groupKey: String?
        let standalone: ManagedWallet?
    }

    /// A record that stays its own wallet: unchanged, store file and all.
    private static func standaloneWallet(_ record: ManagedWallet) -> ManagedWallet { record }

    /// The moves that carry a merged record's chain data to its new account store. The scoped
    /// `<id>-<network>.sqlite` (+`-wal`/`-shm`) when present; else the pre-2026-06 un-namespaced
    /// `<id>.sqlite` family, which `makePersister` would otherwise only ever migrate under the OLD id.
    /// No files → no moves; BDK creates the store fresh on first open.
    private static func storeMoves(for record: ManagedWallet, to destination: String,
                                   files: Set<String>) -> [PlannedFileMove] {
        let suffixes = ["", "-wal", "-shm"]
        let scoped = WalletAccount.legacyStoreName(walletId: record.id, network: record.network)
        let unscoped = "\(record.id).sqlite"
        let base = files.contains(scoped) ? scoped : (files.contains(unscoped) ? unscoped : nil)
        guard let base = base else { return [] }
        var out: [PlannedFileMove] = []
        for suffix in suffixes {
            let from = "\(base)\(suffix)"
            if files.contains(from) {
                out.append(PlannedFileMove(from: from, to: "\(destination)\(suffix)"))
            }
        }
        return out
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
