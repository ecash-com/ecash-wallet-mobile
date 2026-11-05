// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

/// The verdict logic, separated from I/O because this is exactly where the first implementation was
/// wrong: it inferred "Bitcoin doesn't know this transaction" from a 404 on Esplora's OUTSPEND
/// endpoint, which never 404s — it answers from the spend index and reports `{"spent":false}` for
/// txids it has never seen. Every eCash-only coin was therefore classified as still shared with
/// Bitcoin, including the fresh output a split had just created, so the nudge never cleared.
@Suite struct SplitCheckTests {

    @Test func bitcoinNeverSawItSoItCannotReplay() {
        #expect(SplitCheckService.verdict(txExistsOnBitcoin: false, spent: nil) == .chainSpecific)
        // The spent flag is irrelevant when the transaction isn't there at all — this is the case
        // the original bug got backwards.
        #expect(SplitCheckService.verdict(txExistsOnBitcoin: false, spent: false) == .chainSpecific)
    }

    @Test func liveOnBothChainsNeedsSplitting() {
        #expect(SplitCheckService.verdict(txExistsOnBitcoin: true, spent: false) == .shared)
    }

    @Test func alreadySpentOnBitcoinIsEffectivelySplit() {
        // Replaying our eCash spend onto Bitcoin would be a double-spend, so it can't happen.
        #expect(SplitCheckService.verdict(txExistsOnBitcoin: true, spent: true) == .chainSpecific)
    }

    @Test func noAnswerIsUnknownNotSafe() {
        // "We couldn't tell" must never collapse into "you're fine" on a money screen.
        #expect(SplitCheckService.verdict(txExistsOnBitcoin: true, spent: nil) == .unknown)
    }

    // MARK: - The one automatic check after import / copy

    @Test func anImportedWalletOwesOneCheckUntilItSucceeds() {
        let store = SplitCheckStore()
        let id = "split-pending-\(UUID().uuidString)"
        defer { store.forget(walletId: id) }
        #expect(!store.needsInitialCheck(walletId: id))      // nothing owed by default (e.g. create)
        store.markNeedsInitialCheck(walletId: id)
        #expect(store.needsInitialCheck(walletId: id))
        store.clearInitialCheck(walletId: id)
        #expect(!store.needsInitialCheck(walletId: id))
    }

    /// Removing a wallet must not leave a check owed to a future wallet that reuses nothing but the
    /// storage key (Golden Rule §5).
    @Test func removingAWalletDropsItsOwedCheck() {
        let store = SplitCheckStore()
        let id = "split-pending-\(UUID().uuidString)"
        store.markNeedsInitialCheck(walletId: id)
        store.forget(walletId: id)
        #expect(!store.needsInitialCheck(walletId: id))
    }

    /// The seed-container migration folds a copy's record into the wallet it came from; its
    /// split-check cache follows (results merge, the owed check carries over, the old id is gone),
    /// and an answer the surviving wallet already has is never overwritten.
    @Test func rekeyCarriesAMergedRecordsStateToItsWallet() {
        let store = SplitCheckStore()
        let old = "split-rekey-old-\(UUID().uuidString)"
        let new = "split-rekey-new-\(UUID().uuidString)"
        defer { store.forget(walletId: old); store.forget(walletId: new) }
        store.merge(["a:0": .shared, "b:1": .chainSpecific], walletId: old)
        store.merge(["b:1": .shared], walletId: new)            // the wallet's own, newer answer
        store.markNeedsInitialCheck(walletId: old)

        store.rekey(from: old, to: new)

        #expect(store.results(walletId: new)["a:0"] == .shared)
        #expect(store.results(walletId: new)["b:1"] == .shared)   // kept its own
        #expect(store.results(walletId: old).isEmpty)
        #expect(store.needsInitialCheck(walletId: new))
        #expect(!store.needsInitialCheck(walletId: old))
        #expect(store.lastCheckedEpochSeconds(walletId: old) == nil)
        #expect(store.lastCheckedEpochSeconds(walletId: new) != nil)
    }

    /// "Couldn't reach Bitcoin" is never recorded, so it can't stand in for an answer.
    @Test func unknownVerdictsAreNotStored() {
        let store = SplitCheckStore()
        let id = "split-pending-\(UUID().uuidString)"
        defer { store.forget(walletId: id) }
        store.merge(["a:0": .unknown, "b:0": .shared, "c:0": .chainSpecific], walletId: id)
        let known = store.partitioned(walletId: id)
        #expect(known.shared == ["b:0"])
        #expect(known.safe == ["c:0"])
    }
}
