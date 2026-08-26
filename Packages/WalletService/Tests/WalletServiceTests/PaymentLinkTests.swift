// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// Deep-link routing. eCash is byte-identical to Bitcoin, so the scheme is the only thing that can
/// state which chain a payment means — and choosing wrong sends real value to a chain the payee
/// will never watch. That makes this the money-safety core of the feature.
final class PaymentLinkTests: XCTestCase {

    func testSchemeAndBodySplit() {
        XCTAssertEqual(PaymentLink.scheme(of: "bitcoin:bc1qabc"), PaymentScheme.bitcoin)
        XCTAssertEqual(PaymentLink.scheme(of: "ecash:bc1qabc"), PaymentScheme.ecash)
        XCTAssertEqual(PaymentLink.scheme(of: "bc1qabc"), PaymentScheme.none)
        // Schemes are case-insensitive in the wild.
        XCTAssertEqual(PaymentLink.scheme(of: "BITCOIN:bc1qabc"), PaymentScheme.bitcoin)
        XCTAssertEqual(PaymentLink.scheme(of: "ECash:bc1qabc"), PaymentScheme.ecash)

        // The body keeps its original casing and the whole query — BIP21 parses it next.
        XCTAssertEqual(PaymentLink.body(of: "bitcoin:bc1qABC?amount=0.5"), "bc1qABC?amount=0.5")
        XCTAssertEqual(PaymentLink.body(of: "ecash:bc1qABC"), "bc1qABC")
        XCTAssertEqual(PaymentLink.body(of: "  bc1qABC  "), "bc1qABC")
    }

    /// The strict mapping: a scheme is a statement about the chain, and we honor it.
    func testSchemeSelectsTheNetwork() {
        XCTAssertEqual(PaymentLink.routing(scheme: .bitcoin, address: "bc1qabc").networks, [WalletNetwork.bitcoin])
        XCTAssertEqual(PaymentLink.routing(scheme: .ecash, address: "bc1qabc").networks, [WalletNetwork.ecash])
    }

    /// A bare mainnet-class address is valid on BOTH chains and nothing says which — so we ask
    /// rather than guess. This is our own Receive QR's shape, and most pasted addresses.
    func testBareAddressIsAmbiguousAcrossBitcoinAndECash() {
        let routing = PaymentLink.routing(scheme: PaymentScheme.none, address: "bc1qabc")
        XCTAssertTrue(routing.isAmbiguous)
        XCTAssertEqual(routing.networks, [WalletNetwork.bitcoin, WalletNetwork.ecash])
        XCTAssertNil(routing.rejection)
    }

    /// Testnet-class addresses can't be mainnet coins whatever the scheme claims, so the address
    /// wins — a `bitcoin:` link to a tb1 address is a signet request, not a mainnet one.
    func testTestnetAddressRoutesToSignetRegardlessOfScheme() {
        XCTAssertEqual(PaymentLink.routing(scheme: .bitcoin, address: "tb1qabc").networks, [WalletNetwork.signet])
        XCTAssertEqual(PaymentLink.routing(scheme: PaymentScheme.none, address: "tb1qabc").networks, [WalletNetwork.signet])
        XCTAssertFalse(PaymentLink.routing(scheme: .bitcoin, address: "tb1qabc").isAmbiguous)
    }

    /// XEC (the Bitcoin ABC fork) has used `ecash:` since 2021. We can't pay those, but we CAN say
    /// so precisely instead of failing obscurely.
    func testXECCashAddrIsRejectedWithAnHonestReason() {
        let routing = PaymentLink.routing(scheme: .ecash, address: "qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a")
        XCTAssertTrue(routing.networks.isEmpty)
        XCTAssertNotNil(routing.rejection)
        XCTAssertTrue(PaymentLink.noWalletMessage(for: routing).contains("XEC"))
    }

    /// The detection must never swallow OUR addresses — a false positive here would reject real
    /// payments as "that's XEC".
    func testOurAddressesAreNeverMistakenForXEC() {
        XCTAssertFalse(PaymentLink.isXECCashAddr("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))
        XCTAssertFalse(PaymentLink.isXECCashAddr("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"))
        XCTAssertFalse(PaymentLink.isXECCashAddr("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"))
        XCTAssertFalse(PaymentLink.isXECCashAddr("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"))
    }

    /// Messages must name the chain that was asked for; "no wallet found" leaves a user unable to
    /// tell a missing wallet from a link for the wrong chain.
    func testEmptyMessagesSayWhichChainWasRequested() {
        let bitcoin = PaymentLink.routing(scheme: .bitcoin, address: "bc1qabc")
        XCTAssertTrue(PaymentLink.noWalletMessage(for: bitcoin).contains("Bitcoin"))
        let ecash = PaymentLink.routing(scheme: .ecash, address: "bc1qabc")
        XCTAssertTrue(PaymentLink.noWalletMessage(for: ecash).contains("eCash"))
        let bare = PaymentLink.routing(scheme: PaymentScheme.none, address: "bc1qabc")
        XCTAssertTrue(PaymentLink.noWalletMessage(for: bare).contains("Bitcoin or eCash"))
    }
}
