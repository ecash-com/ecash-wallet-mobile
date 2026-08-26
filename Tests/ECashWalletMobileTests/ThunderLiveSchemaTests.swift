// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// Decoding pinned to JSON captured from a REAL Thunder node — 157.180.96.24:16009 on 2026-08-26,
/// the first one that ever had UTXOs in it. Every earlier response was an empty array, so none of
/// this was exercised: the methods existed and answered, and the shapes were still guesses.
///
/// The catch it found: `Deposit` is serialized as the STRING "txid:vout" (bitcoin::OutPoint's
/// Display), while `Regular` and `Coinbase` use objects. We decoded all three as objects, so the
/// first real deposit would have failed the whole response.
@Suite struct ThunderLiveSchemaTests {

    private func decode(_ json: String) throws -> ThunderRPCPointedOutput {
        try JSONDecoder().decode(ThunderRPCPointedOutput.self, from: Data(json.utf8))
    }

    @Test func decodesDepositAsAFlatString() throws {
        // Verbatim from list_utxos.
        let json = """
        {"outpoint":{"Deposit":"7676902c70472aa685fd37fab6561ec21587124ae69a956ce1513cc78cc0a6b9:0"},
         "output":{"address":"4Wh9tjf2chyMHy73EKXtrGj7zgjp","content":{"Value":1000000}}}
        """
        let pointed = try decode(json)
        #expect(pointed.output.content.valueSats == 1_000_000)
    }

    @Test func decodesRegularAndCoinbaseObjects() throws {
        let regular = """
        {"outpoint":{"Regular":{"txid":"31c7c68bf0eaca59338c8a8c264b29cbd3e7434dc3482647afd90f689a5e51bc","vout":1}},
         "output":{"address":"q339XXYJfJ6w539LrNwVDRaZXAX","content":{"Value":211399707}}}
        """
        #expect(try decode(regular).output.content.valueSats == 211_399_707)

        let coinbase = """
        {"outpoint":{"Coinbase":{"merkle_root":"9ad056302eac8a15b66ed29c538ad69f8d739d64504fb0c2684adafefbc4e136","vout":0}},
         "output":{"address":"3QUz9CznmFmdkeNYPBtGsV6obE1P","content":{"Value":100}}}
        """
        #expect(try decode(coinbase).output.content.valueSats == 100)
    }

    /// A malformed deposit string must fail loudly rather than decode to a wrong outpoint — getting
    /// this wrong would spend against a coin that isn't there.
    @Test func rejectsAMalformedDepositString() {
        let json = """
        {"outpoint":{"Deposit":"not-a-txid:0"},
         "output":{"address":"4Wh9tjf2chyMHy73EKXtrGj7zgjp","content":{"Value":1}}}
        """
        #expect(throws: (any Error).self) { try decode(json) }
    }
}
