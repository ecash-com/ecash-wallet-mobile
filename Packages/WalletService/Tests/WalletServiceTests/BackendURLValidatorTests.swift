// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// Backend URL syntax. The scheme picks the transport BDK will attempt — Electrum over a raw or
/// TLS socket, Esplora over HTTP — and neither client falls back to the other, so a mismatched URL
/// presents as a dead server rather than a configuration error.
final class BackendURLValidatorTests: XCTestCase {

    // Two statements on purpose. A single-expression Swift body transpiles to a Kotlin EXPRESSION
    // body (`private fun ok(...): Unit = XCTAssertNil(...)`), and SkipUnit's assertions don't return
    // Unit — so the Kotlin compile fails with "Return type mismatch: expected 'Unit', actual
    // 'String'". Binding first forces a block body. Only `swift test`'s Robolectric leg catches
    // this; the Swift build is happy either way.
    private func ok(_ kind: String, _ url: String) {
        let message = BackendURLValidator.validationMessage(kind: kind, url: url)
        XCTAssertNil(message)
    }
    private func bad(_ kind: String, _ url: String) {
        let message = BackendURLValidator.validationMessage(kind: kind, url: url)
        XCTAssertNotNil(message)
    }

    func testAcceptsTheRealDefaults() {
        ok("electrum", "ssl://electrum.blockstream.info:50002")
        ok("electrum", "tcp://node.signet.drivechain.info:50001")
        ok("esplora", "https://esplora.mainnet.drivechain.info")
        ok("esplora", "http://192.168.1.10:3002")
        ok("esplora", "https://node.signet.drivechain.info/api")   // path is fine for Esplora
    }

    /// The mistake most likely to be made: pasting one kind's URL under the other's setting.
    func testRejectsCrossedSchemes() {
        bad("electrum", "https://esplora.mainnet.drivechain.info")
        bad("esplora", "ssl://electrum.blockstream.info:50002")
    }

    func testRejectsGarbage() {
        bad("electrum", "electrum.blockstream.info:50002")   // no scheme at all
        bad("esplora", "esplora.mainnet.drivechain.info")
        bad("electrum", "ssl://")                            // scheme but no host
        bad("esplora", "https://")
        bad("esplora", "https://host name/api")              // pasted with a space
    }

    /// Electrum has no default port, so the client can't guess one — an address without a port just
    /// fails to connect, which is indistinguishable from a server being down.
    func testElectrumRequiresAUsablePort() {
        bad("electrum", "ssl://electrum.blockstream.info")
        bad("electrum", "ssl://electrum.blockstream.info:0")
        bad("electrum", "ssl://electrum.blockstream.info:70000")
        bad("electrum", "ssl://electrum.blockstream.info:abc")
        bad("electrum", "ssl://electrum.blockstream.info:50002/api")   // path is meaningless here
        ok("electrum", "ssl://[::1]:50002")                            // IPv6 literal survives
    }

    /// Self-hosting is a first-class case: a raw IP, localhost, or an .onion is what you type when
    /// you run your own node, and none of them have to look like a domain name.
    func testAcceptsRawAddressesAndOnions() {
        ok("electrum", "ssl://192.168.1.10:50002")
        ok("electrum", "tcp://127.0.0.1:50001")
        ok("electrum", "tcp://localhost:50001")
        ok("esplora", "http://192.168.1.10:3002")
        ok("esplora", "http://localhost:3002")
        ok("esplora", "http://10.0.0.5:3002/api")
        // IPv6 literals: the port split takes the LAST colon, so the address survives intact.
        ok("electrum", "ssl://[2001:db8::1]:50002")
        ok("esplora", "http://[::1]:3002")
        // Tor, which is the whole reason the SOCKS5 proxy setting exists.
        ok("electrum", "tcp://abcdefghijklmnop.onion:50001")
        ok("esplora", "http://abcdefghijklmnop.onion/api")
    }

    /// Empty is not "invalid" — it's how the editor says "clear my override".
    func testEmptyIsNotAnError() {
        XCTAssertNil(BackendURLValidator.validationMessage(kind: "electrum", url: ""))
        XCTAssertNil(BackendURLValidator.validationMessage(kind: "esplora", url: "   "))
    }
}
