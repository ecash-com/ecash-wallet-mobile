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

/// A BDK store rename, basenames within the chain-data directory — the `.sqlite` file; its
/// `-wal`/`-shm` sidecars travel with it (`WalletEngineFactory.moveChainDataStore`). One per merged
/// record that has a store, tagged with that record so the applier can verify and revert it.
struct PlannedFileMove: Equatable, Codable {
    let legacyId: String
    // Not `from`/`to`: inside Skip's generated Kotlin `encode(to: Encoder)` a property named `to`
    // resolves to the encoder parameter, and the report encodes the encoder (ClassCastException).
    let source: String
    let destination: String
}

/// A per-`walletId` app store (e.g. `SplitCheckStore`) whose key must follow a merged record. Also
/// the legacy-id → wallet-id map (`mergedInto`) the app uses to restore a selection.
struct PlannedRekey: Equatable, Codable {
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
        // Moves: distinct destinations, never onto a source, never a no-op, each for a merged record.
        var destinations = Set<String>()
        let sources = Set(fileMoves.map { $0.source })
        let mergedIds = Set(rekeys.map { $0.legacyId })
        for m in fileMoves {
            if m.source == m.destination { problems.append("no-op move \(m.source)") }
            if destinations.contains(m.destination) { problems.append("two moves to \(m.destination)") }
            destinations.insert(m.destination)
            if sources.contains(m.destination) { problems.append("move onto a source \(m.destination)") }
            if !mergedIds.contains(m.legacyId) { problems.append("move for unmerged \(m.legacyId)") }
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
        guard record.accounts.count == 1, record.keyType == .mnemonic, !record.network.isThunder else {
            return nil
        }
        return record.masterFingerprint
    }

    /// - Parameters:
    ///   - keepStandalone: legacy ids that must NOT be merged even if they match a group — the
    ///     applier re-plans with the ids whose store failed verification (§6.3), so a failed record
    ///     stays its own wallet, untouched, and the rest of the migration still proceeds.
    static func plan(legacy: [ManagedWallet], chainDataFiles: [String], selectedId: String?,
                     keepStandalone: [String] = []) -> MigrationPlan {
        let files = Set(chainDataFiles)
        let pinned = Set(keepStandalone)
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
            if !pinned.contains(record.id), let key = mergeKey(for: record) {
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
        var keptStandalone: [String] = keepStandalone
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
                // A destination that already exists is a CONFLICT only while the source is still
                // there too. Destination present + source gone = an interrupted earlier run already
                // moved it; plan the move and the applier verifies it in place (§6.3).
                let hasSource = files.contains(WalletAccount.legacyStoreName(walletId: secondary.id, network: secondary.network))
                    || files.contains("\(secondary.id).sqlite")
                let conflict = hasSource && files.contains { $0.hasPrefix(destination) }
                if takenAccountIds.contains(accountId) || conflict || claimedDestinations.contains(destination) {
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
                if let move = storeMove(for: secondary, to: destination, files: files) {
                    moves.append(move)
                }
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

    /// The move that carries a merged record's chain data to its new account store: the scoped
    /// `<id>-<network>.sqlite` when present, else the pre-2026-06 un-namespaced `<id>.sqlite`, which
    /// `makePersister` would otherwise only ever migrate under the OLD id. Sidecars follow at apply
    /// time. Destination already present with no source = moved by an interrupted run; the move is
    /// still planned (source = the scoped name) so the applier verifies it in place. No file either
    /// side → no move; BDK creates the store fresh on first open.
    private static func storeMove(for record: ManagedWallet, to destination: String,
                                  files: Set<String>) -> PlannedFileMove? {
        let scoped = WalletAccount.legacyStoreName(walletId: record.id, network: record.network)
        let unscoped = "\(record.id).sqlite"
        if files.contains(scoped) || files.contains(destination) {
            return PlannedFileMove(legacyId: record.id, source: scoped, destination: destination)
        }
        if files.contains(unscoped) {
            return PlannedFileMove(legacyId: record.id, source: unscoped, destination: destination)
        }
        return nil
    }
}

// MARK: - The APPLIER

/// A merged record the applier backed out of merging, and why. `reason` is a fixed code:
/// `load-before` (its legacy store wouldn't open with its own descriptors), `move` (a rename
/// failed), `load-after` (the moved store wouldn't reopen, or its balance differed). In every
/// case the moves were reverted and the record stays its own wallet, untouched.
struct MigrationExclusion: Equatable, Codable {
    let legacyId: String
    let reason: String
}

/// What the migration did — persisted as `migration-v2.log.json` and kept by `WalletManager` for the
/// app (selection mapping, per-`walletId` store re-keys). **Ids, store names, and counts only**:
/// never a label, a descriptor, or anything from the Keychain (Golden Rule §2; pinned by
/// `testReportNeverContainsLabelsOrDescriptors`).
struct MigrationReport: Equatable, Codable {
    let version: Int
    let appliedAtEpochSeconds: Int64
    let summary: String
    let walletIds: [String]
    let moves: [PlannedFileMove]
    let rekeys: [PlannedRekey]
    let keptStandalone: [String]
    let excluded: [MigrationExclusion]
    let selectedWalletId: String?

    /// The wallet a legacy id now lives in: itself, or the primary it was merged into.
    func walletId(forLegacy id: String) -> String? {
        if walletIds.contains(id) { return id }
        return rekeys.first { $0.legacyId == id }?.walletId
    }
}

/// Applies a verified `MigrationPlan` (`docs/seed-container-model.md §6.3`): snapshot the legacy
/// list, move each merged record's store with a BDK reopen + balance check on either side, back
/// out any record that fails, write the report, commit v2. Reaches files only through the factory
/// and the wallet list only through the store; has **no `KeyStore`** (invariant I1) and no logging
/// of its own.
///
/// Retry-safe: a failure before `commitV2` leaves the legacy list authoritative and the next launch
/// runs again; a store already moved is recognised (source gone, destination present) and verified
/// in place rather than moved twice.
// SKIP @nobridge
public final class WalletMigrationV2Applier {
    private let store: WalletStore
    private let factory: WalletEngineFactory

    init(store: WalletStore, factory: WalletEngineFactory) {
        self.store = store
        self.factory = factory
    }

    /// Run the migration unless the store is already v2. Returns the report, or `nil` when there
    /// was nothing to do. An **empty** legacy list is still committed (as an empty v2 list) so a
    /// fresh install writes v2 from its first wallet on.
    func migrateIfNeeded(selectedId: String?, nowEpochSeconds: Int64) throws -> MigrationReport? {
        if store.isV2 { return nil }
        let legacy = try store.allWallets()
        try store.beginV2Migration()                         // I5: snapshot before anything moves
        let files = factory.chainDataFileNames()

        var keep: [String] = []
        var excluded: [MigrationExclusion] = []
        var verified = Set<String>()                         // legacy ids moved + checked already
        var plan = WalletStoreMigrationV2.plan(legacy: legacy, chainDataFiles: files,
                                               selectedId: selectedId, keepStandalone: keep)
        var passes = 0
        while true {
            passes += 1
            if passes > legacy.count + 1 { throw WalletError.persistenceFailed }   // can't happen; never spin
            // I2: never apply a plan that doesn't verify.
            if !plan.verify(against: legacy).isEmpty { throw WalletError.persistenceFailed }

            var failure: MigrationExclusion? = nil
            for rekey in plan.rekeys {
                if verified.contains(rekey.legacyId) { continue }
                guard let record = legacy.first(where: { $0.id == rekey.legacyId }),
                      let wallet = plan.wallets.first(where: { $0.id == rekey.walletId }),
                      let account = wallet.account(id: rekey.accountId) else {
                    throw WalletError.persistenceFailed
                }
                guard let move = plan.fileMoves.first(where: { $0.legacyId == rekey.legacyId }) else {
                    verified.insert(rekey.legacyId)          // never synced: nothing to carry
                    continue
                }
                let outcome = carry(record: record, account: account, move: move)
                if let reason = outcome {
                    failure = MigrationExclusion(legacyId: rekey.legacyId, reason: reason)
                    break
                }
                verified.insert(rekey.legacyId)
            }
            guard let failed = failure else { break }
            excluded.append(failed)
            keep.append(failed.legacyId)
            plan = WalletStoreMigrationV2.plan(legacy: legacy, chainDataFiles: files,
                                               selectedId: selectedId, keepStandalone: keep)
        }

        let report = MigrationReport(version: FileWalletStore.v2Version,
                                     appliedAtEpochSeconds: nowEpochSeconds,
                                     summary: plan.summary,
                                     walletIds: plan.wallets.map { $0.id },
                                     moves: plan.fileMoves, rekeys: plan.rekeys,
                                     keptStandalone: plan.keptStandalone, excluded: excluded,
                                     selectedWalletId: plan.selectedWalletId)
        try store.saveMigrationReport(try JSONEncoder().encode(report))
        try store.commitV2(plan.wallets)                      // the one-way switch, last
        return report
    }

    /// Move one record's store to its account name and prove nothing changed: the store must open
    /// with the record's descriptors before (I3) and after, with the same balance (I4). Returns a
    /// failure reason, or `nil` on success. On failure the move is undone.
    private func carry(record: ManagedWallet, account: WalletAccount, move: PlannedFileMove) -> String? {
        let keyType = record.keyType
        let alreadyMoved = !factory.chainDataFileNames().contains(move.source)
            && factory.chainDataFileNames().contains(move.destination)
        if alreadyMoved {
            // A retry after an interrupted run: verify in place.
            return (try? factory.cachedBalance(storeName: move.destination, account: account, keyType: keyType)) == nil
                ? "load-after" : nil
        }
        let before: Int64
        do {
            before = try factory.cachedBalance(storeName: move.source, account: account, keyType: keyType)
        } catch {
            return "load-before"
        }
        do {
            try factory.moveChainDataStore(from: move.source, to: move.destination)
        } catch {
            return "move"
        }
        if let after = try? factory.cachedBalance(storeName: move.destination, account: account, keyType: keyType),
           after == before {
            return nil
        }
        try? factory.moveChainDataStore(from: move.destination, to: move.source)   // revert; the record stays standalone
        return "load-after"
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
