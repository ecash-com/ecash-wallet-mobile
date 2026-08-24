// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

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
}
