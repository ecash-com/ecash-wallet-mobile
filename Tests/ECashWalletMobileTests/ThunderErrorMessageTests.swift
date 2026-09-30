// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import ECashWalletMobile

@Suite struct ThunderErrorMessageTests {
    /// The node's live rejection for spending a not-yet-confirmed output (2026-09-30).
    private let unconfirmedRejection = "submit transaction: submit_transaction: node error -1: node error: state error: utreexo error (Could not find node)"

    @Test func spendingAnUnconfirmedCoinGetsAPlainExplanation() {
        let error = ThunderBackendError.server(code: 400, message: unconfirmedRejection)
        #expect(error.userMessage.contains("aren't confirmed yet"))
    }

    @Test func otherRejectionsAndOutagesAreDistinct() {
        #expect(ThunderBackendError.server(code: 400, message: "failed to verify authorization").userMessage
                == "The Thunder network rejected this transaction.")
        #expect(ThunderBackendError.server(code: 502, message: "bad gateway").userMessage.contains("had a problem"))
        #expect(ThunderBackendError.network.userMessage.contains("Couldn't reach"))
        #expect(ThunderBackendError.server(code: 404, message: "not found").userMessage != ThunderBackendError.network.userMessage)
    }

    @Test func insufficientFundsMentionsConfirmation() {
        #expect(ThunderError.insufficientFunds(neededSats: 10, availableSats: 5).userMessage.contains("confirmed"))
    }

    /// Nothing in a Thunder error message may echo key material — the messages are fixed text.
    @Test func messagesNeverEchoTheServerReply() {
        let error = ThunderBackendError.server(code: 400, message: "SECRET-LOOKING-DETAIL")
        #expect(!error.userMessage.contains("SECRET"))
    }
}
