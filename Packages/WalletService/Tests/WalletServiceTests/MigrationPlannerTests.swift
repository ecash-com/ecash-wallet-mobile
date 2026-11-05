// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// The seed-container migration planner (`docs/seed-container-model.md §6`, §9 "Pure"). Pure and
/// deterministic: legacy records + file names in, a plan out. Nothing here touches BDK, disk, or
/// the Keychain — which is the point (invariant I1). Every case the doc lists is pinned below.
final class MigrationPlannerTests: XCTestCase {

    // Two seeds, by master fingerprint. Real descriptor shapes (origin + account-level key).
    private static let fpA = "d34db33f"
    private static let fpB = "0badf00d"

    private func hd(_ id: String, _ network: WalletNetwork, fp: String = MigrationPlannerTests.fpA,
                    script: ScriptType = .bip84, account: Int32 = 0, sort: Int = 0,
                    label: String = "Wallet", backedUp: Bool = false) -> ManagedWallet {
        let coin = network == .signet ? "1" : "0"
        let key = network == .signet ? "tpubDC...\(id)" : "xpub6C...\(id)"
        let ext = "wpkh([\(fp)/\(script.purpose)'/\(coin)'/\(account)']\(key)/0/*)#aaaaaaaa"
        let int = "wpkh([\(fp)/\(script.purpose)'/\(coin)'/\(account)']\(key)/1/*)#bbbbbbbb"
        return ManagedWallet(id: id, label: label, network: network,
                             externalDescriptor: ext, internalDescriptor: int,
                             keyType: .mnemonic, scriptType: script, accountIndex: account,
                             isBackedUp: backedUp, sortIndex: sort)
    }

    private func wifRecord(_ id: String, _ network: WalletNetwork, sort: Int = 0) -> ManagedWallet {
        ManagedWallet(id: id, label: "Claim", network: network,
                      externalDescriptor: "pkh(02ab...cd)#cccccccc", internalDescriptor: "pkh(02ab...cd)#cccccccc",
                      keyType: .wif, scriptType: .bip84, accountIndex: 0, isBackedUp: true, sortIndex: sort)
    }

    private func thunderRecord(_ id: String, sort: Int = 0) -> ManagedWallet {
        ManagedWallet(id: id, label: "Thunder", network: .thunder,
                      externalDescriptor: "", internalDescriptor: "",
                      keyType: .mnemonic, scriptType: .bip84, accountIndex: 0, isBackedUp: false, sortIndex: sort)
    }

    private func storeFiles(_ id: String, _ network: WalletNetwork, wal: Bool = true) -> [String] {
        var out = ["\(id)-\(network.rawValue).sqlite"]
        if wal {
            out.append("\(id)-\(network.rawValue).sqlite-wal")
            out.append("\(id)-\(network.rawValue).sqlite-shm")
        }
        return out
    }

    private func plan(_ legacy: [ManagedWallet], files: [String] = [], selected: String? = nil) -> MigrationPlan {
        let p = WalletStoreMigrationV2.plan(legacy: legacy, chainDataFiles: files, selectedId: selected)
        XCTAssertTrue(p.verify(against: legacy).isEmpty, "plan must verify clean: \(p.verify(against: legacy))")
        return p
    }

    // MARK: - Fingerprint

    func testMasterFingerprintParsesOriginLowercased() {
        XCTAssertEqual(ManagedWallet.masterFingerprint("wpkh([D34DB33F/84'/0'/0']xpub.../0/*)"), "d34db33f")
        XCTAssertEqual(ManagedWallet.masterFingerprint("tr([0badf00d/86h/0h/0h]xpub.../0/*)#abcd"), "0badf00d")
    }

    func testMasterFingerprintIsNilWithoutAnOrigin() {
        XCTAssertNil(ManagedWallet.masterFingerprint("pkh(02ab...cd)"))          // WIF: no origin
        XCTAssertNil(ManagedWallet.masterFingerprint(""))                        // Thunder: no descriptor
        XCTAssertNil(ManagedWallet.masterFingerprint("wpkh([zzzzzzzz/84'/0'/0']xpub/0/*)"))  // not hex
        XCTAssertNil(ManagedWallet.masterFingerprint("wpkh([d34db3/84'/0'/0']xpub/0/*)"))    // not 8 digits
        // An origin with the fingerprint alone is still a fingerprint.
        XCTAssertEqual(ManagedWallet.masterFingerprint("wpkh([d34db33f]xpub/0/*)"), "d34db33f")
    }

    func testFingerprintSameAcrossCoinTypeAndScriptType() {
        XCTAssertEqual(hd("a", .ecashMainnet).masterFingerprint, hd("b", .signet).masterFingerprint)
        XCTAssertEqual(hd("a", .ecashMainnet).masterFingerprint, hd("c", .bitcoin, script: .bip86).masterFingerprint)
        XCTAssertNotEqual(hd("a", .ecashMainnet).masterFingerprint, hd("d", .ecashMainnet, fp: Self.fpB).masterFingerprint)
    }

    // MARK: - One record → one wallet, nothing moves

    func testSingleRecordBecomesOneWalletOneAccountNoMoves() {
        let legacy = [hd("w1", .ecashMainnet, sort: 0, label: "Main", backedUp: true)]
        let p = plan(legacy, files: storeFiles("w1", .ecashMainnet), selected: "w1")
        XCTAssertEqual(p.wallets.count, 1)
        let w = p.wallets[0]
        XCTAssertEqual(w.id, "w1")
        XCTAssertEqual(w.label, "Main")
        XCTAssertTrue(w.isBackedUp)
        XCTAssertEqual(w.accounts.count, 1)
        XCTAssertEqual(w.accounts[0].id, "ecashMainnet-bip84-0")
        XCTAssertEqual(w.accounts[0].storeName, "w1-ecashMainnet.sqlite")   // keeps the file it has
        XCTAssertEqual(w.selectedAccountId, "ecashMainnet-bip84-0")
        XCTAssertTrue(w.mergedFrom.isEmpty)
        XCTAssertTrue(w.orphanKeychainIds.isEmpty)
        XCTAssertTrue(p.fileMoves.isEmpty)
        XCTAssertTrue(p.rekeys.isEmpty)
        XCTAssertEqual(p.selectedWalletId, "w1")
    }

    func testUnrelatedSeedsStaySeparate() {
        let p = plan([hd("a", .ecashMainnet, sort: 0), hd("b", .ecashMainnet, fp: Self.fpB, sort: 1)])
        XCTAssertEqual(p.wallets.map { $0.id }, ["a", "b"])
        XCTAssertTrue(p.fileMoves.isEmpty)
    }

    // MARK: - Copies of one seed merge

    func testCopyOnAnotherNetworkMergesIntoThePrimary() {
        let legacy = [hd("orig", .ecashMainnet, sort: 0, label: "Wallet 1"),
                      hd("copy", .bitcoin, sort: 1, label: "Wallet 1 (Bitcoin)", backedUp: true)]
        let files = storeFiles("orig", .ecashMainnet) + storeFiles("copy", .bitcoin)
        let p = plan(legacy, files: files, selected: "orig")

        XCTAssertEqual(p.wallets.count, 1)
        let w = p.wallets[0]
        XCTAssertEqual(w.id, "orig")                       // lowest sortIndex survives
        XCTAssertEqual(w.label, "Wallet 1")                // the copy's suffix label is dropped
        XCTAssertTrue(w.isBackedUp)                        // OR of the group
        XCTAssertEqual(w.accounts.map { $0.id }, ["ecashMainnet-bip84-0", "bitcoin-bip84-0"])
        XCTAssertEqual(w.accounts[0].storeName, "orig-ecashMainnet.sqlite")
        XCTAssertEqual(w.accounts[1].storeName, "orig-bitcoin-bip84-0.sqlite")
        XCTAssertEqual(w.accounts[1].sourceId, "copy")
        XCTAssertEqual(w.accounts[1].externalDescriptor, legacy[1].externalDescriptor)
        XCTAssertEqual(w.mergedFrom, ["copy"])
        XCTAssertEqual(w.orphanKeychainIds, ["copy"])      // recorded, never deleted here
        XCTAssertEqual(w.selectedAccountId, "ecashMainnet-bip84-0")

        XCTAssertEqual(p.fileMoves, [
            PlannedFileMove(from: "copy-bitcoin.sqlite", to: "orig-bitcoin-bip84-0.sqlite"),
            PlannedFileMove(from: "copy-bitcoin.sqlite-wal", to: "orig-bitcoin-bip84-0.sqlite-wal"),
            PlannedFileMove(from: "copy-bitcoin.sqlite-shm", to: "orig-bitcoin-bip84-0.sqlite-shm"),
        ])
        XCTAssertEqual(p.rekeys, [PlannedRekey(legacyId: "copy", walletId: "orig", accountId: "bitcoin-bip84-0")])
        XCTAssertEqual(p.selectedWalletId, "orig")
    }

    func testPrimaryIsLowestSortIndexNotInputOrder() {
        let legacy = [hd("later", .bitcoin, sort: 5), hd("first", .ecashMainnet, sort: 2)]
        let p = plan(legacy)
        XCTAssertEqual(p.wallets.map { $0.id }, ["first"])
        XCTAssertEqual(p.wallets[0].mergedFrom, ["later"])
    }

    func testSelectionFollowsAMergedSecondary() {
        let legacy = [hd("orig", .ecashMainnet, sort: 0), hd("copy", .signet, sort: 1)]
        let p = plan(legacy, selected: "copy")
        XCTAssertEqual(p.selectedWalletId, "orig")
        XCTAssertEqual(p.wallets[0].selectedAccountId, "signet-bip84-0")   // lands on the same balance
    }

    func testDifferentScriptTypesOfOneSeedBecomeAccounts() {
        let legacy = [hd("a", .ecashMainnet, sort: 0), hd("b", .ecashMainnet, script: .bip86, sort: 1)]
        let p = plan(legacy, files: storeFiles("b", .ecashMainnet, wal: false))
        XCTAssertEqual(p.wallets.count, 1)
        XCTAssertEqual(p.wallets[0].accounts.map { $0.id }, ["ecashMainnet-bip84-0", "ecashMainnet-bip86-0"])
        XCTAssertEqual(p.fileMoves, [PlannedFileMove(from: "b-ecashMainnet.sqlite", to: "a-ecashMainnet-bip86-0.sqlite")])
    }

    func testSecondaryWithoutAStoreMergesWithNoMoves() {
        let p = plan([hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1)], files: storeFiles("a", .ecashMainnet))
        XCTAssertEqual(p.wallets[0].accounts.count, 2)
        XCTAssertTrue(p.fileMoves.isEmpty)                    // BDK creates it fresh on first open
        XCTAssertEqual(p.wallets[0].accounts[1].storeName, "a-bitcoin-bip84-0.sqlite")
    }

    func testUnnamespacedLegacyStoreOfASecondaryMovesToo() {
        // A pre-2026-06 store `<id>.sqlite` that makePersister never got to rename under its old id.
        let p = plan([hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1)],
                     files: ["b.sqlite", "b.sqlite-wal"])
        XCTAssertEqual(p.fileMoves, [
            PlannedFileMove(from: "b.sqlite", to: "a-bitcoin-bip84-0.sqlite"),
            PlannedFileMove(from: "b.sqlite-wal", to: "a-bitcoin-bip84-0.sqlite-wal"),
        ])
    }

    func testThreeWayMergeAcrossNetworksAndScriptTypes() {
        let legacy = [hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1),
                      hd("c", .signet, sort: 2), hd("d", .signet, script: .bip86, sort: 3)]
        let p = plan(legacy, selected: "d")
        XCTAssertEqual(p.wallets.count, 1)
        XCTAssertEqual(p.wallets[0].accounts.count, 4)
        XCTAssertEqual(p.wallets[0].mergedFrom, ["b", "c", "d"])
        XCTAssertEqual(p.wallets[0].selectedAccountId, "signet-bip86-0")
        XCTAssertEqual(p.rekeys.count, 3)
    }

    // MARK: - Never merged

    func testWifRecordsNeverMergeEvenWithIdenticalDescriptors() {
        let p = plan([wifRecord("claim", .ecashMainnet, sort: 0), wifRecord("claimBtc", .bitcoin, sort: 1)])
        XCTAssertEqual(p.wallets.map { $0.id }, ["claim", "claimBtc"])
        XCTAssertEqual(p.wallets[0].keyType, WalletKeyType.wif)
        XCTAssertEqual(p.wallets[0].accounts[0].storeName, "claim-ecashMainnet.sqlite")
        XCTAssertTrue(p.fileMoves.isEmpty)
    }

    func testThunderRecordsNeverMergeAndKeepOneAccount() {
        let p = plan([hd("seed", .ecashMainnet, sort: 0), thunderRecord("th", sort: 1)])
        XCTAssertEqual(p.wallets.map { $0.id }, ["seed", "th"])
        XCTAssertEqual(p.wallets[1].accounts.map { $0.id }, ["thunder-bip84-0"])
        XCTAssertEqual(p.wallets[1].accounts[0].externalDescriptor, "")
    }

    // MARK: - Not provably safe → kept standalone, never dropped

    func testDuplicateAccountInAGroupKeepsTheLaterRecordStandalone() {
        // Two records on the same (network, scriptType, account) — existingCopy should prevent it,
        // but if it ever happens neither is dropped.
        let legacy = [hd("a", .ecashMainnet, sort: 0), hd("dup", .ecashMainnet, sort: 1)]
        let p = plan(legacy, files: storeFiles("a", .ecashMainnet) + storeFiles("dup", .ecashMainnet))
        XCTAssertEqual(p.wallets.map { $0.id }, ["a", "dup"])
        XCTAssertEqual(p.keptStandalone, ["dup"])
        XCTAssertTrue(p.fileMoves.isEmpty)
        XCTAssertEqual(p.wallets[1].accounts[0].storeName, "dup-ecashMainnet.sqlite")   // untouched
    }

    func testExistingDestinationFileKeepsTheRecordStandalone() {
        let legacy = [hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1)]
        let p = plan(legacy, files: storeFiles("b", .bitcoin) + ["a-bitcoin-bip84-0.sqlite"])   // would clobber
        XCTAssertEqual(p.wallets.map { $0.id }, ["a", "b"])
        XCTAssertEqual(p.keptStandalone, ["b"])
        XCTAssertTrue(p.fileMoves.isEmpty)
    }

    func testMixedListPlacesEveryRecordExactlyOnce() {
        let legacy = [hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1),
                      hd("x", .ecashMainnet, fp: Self.fpB, sort: 2), wifRecord("k", .ecashMainnet, sort: 3),
                      thunderRecord("t", sort: 4), hd("dup", .ecashMainnet, sort: 5)]
        let p = plan(legacy, selected: "x")
        XCTAssertEqual(p.wallets.map { $0.id }, ["a", "x", "k", "t", "dup"])
        XCTAssertEqual(p.wallets.reduce(0) { $0 + $1.accounts.count }, legacy.count)
        XCTAssertEqual(p.selectedWalletId, "x")
        XCTAssertEqual(p.keptStandalone, ["dup"])
    }

    // MARK: - Determinism, idempotence, scrubbing

    func testPlanIsIndependentOfInputOrder() {
        let legacy = [hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, sort: 1),
                      hd("c", .signet, fp: Self.fpB, sort: 2), thunderRecord("t", sort: 3)]
        let files = storeFiles("b", .bitcoin) + storeFiles("a", .ecashMainnet)
        let forward = plan(legacy, files: files, selected: "b")
        let reversed = plan(Array(legacy.reversed()), files: Array(files.reversed()), selected: "b")
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, plan(legacy, files: files, selected: "b"))   // re-run: same plan
    }

    func testUnknownSelectionYieldsNil() {
        XCTAssertNil(plan([hd("a", .ecashMainnet)], selected: "gone").selectedWalletId)
        XCTAssertNil(plan([hd("a", .ecashMainnet)], selected: nil).selectedWalletId)
    }

    func testEmptyListPlansNothing() {
        let none: [ManagedWallet] = []
        let p = plan(none)
        XCTAssertTrue(p.wallets.isEmpty)
        XCTAssertEqual(p.summary, "wallets=0 accounts=0 merged=0 moves=0 rekeys=0 selected=none")
    }

    func testSummaryNeverContainsLabelsOrDescriptors() {
        let legacy = [hd("a", .ecashMainnet, sort: 0, label: "SECRET LABEL"), hd("b", .bitcoin, sort: 1, label: "Other label")]
        let p = plan(legacy, files: storeFiles("b", .bitcoin), selected: "b")
        XCTAssertFalse(p.summary.contains("SECRET"))
        XCTAssertFalse(p.summary.contains("label"))
        XCTAssertFalse(p.summary.contains("xpub"))
        XCTAssertFalse(p.summary.contains("wpkh"))
        XCTAssertEqual(p.summary, "wallets=1 accounts=2 merged=1 moves=3 rekeys=1 selected=a")
    }

    // MARK: - verify() catches a bad plan

    func testVerifyFlagsADroppedRecordAndADuplicateStore() {
        let legacy = [hd("a", .ecashMainnet, sort: 0), hd("b", .bitcoin, fp: Self.fpB, sort: 1)]
        let acct = PlannedAccount(id: "ecashMainnet-bip84-0", network: WalletNetwork.ecashMainnet,
                                  scriptType: ScriptType.bip84, accountIndex: Int32(0),
                                  externalDescriptor: "", internalDescriptor: "",
                                  storeName: "a-ecashMainnet.sqlite", sourceId: "a")
        let onlyA = PlannedWallet(id: "a", label: "", keyType: WalletKeyType.mnemonic, isBackedUp: false, sortIndex: 0,
                                  selectedAccountId: acct.id, accounts: [acct], mergedFrom: [], orphanKeychainIds: [])
        let bad = MigrationPlan(wallets: [onlyA, onlyA], fileMoves: [PlannedFileMove(from: "x", to: "x")],
                                rekeys: [], selectedWalletId: "zzz", keptStandalone: [])
        let problems = bad.verify(against: legacy)
        XCTAssertTrue(problems.contains { $0.contains("duplicate wallet id a") })
        XCTAssertTrue(problems.contains { $0.contains("store a-ecashMainnet.sqlite used twice") })
        XCTAssertTrue(problems.contains { $0.contains("legacy b placed 0 times") })
        XCTAssertTrue(problems.contains { $0.contains("legacy a placed 2 times") })
        XCTAssertTrue(problems.contains { $0.contains("no-op move x") })
        XCTAssertTrue(problems.contains { $0.contains("selected wallet zzz not in plan") })
    }
}
