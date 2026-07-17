// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// Locks down the network-safety invariants (Golden Rule §4): each network resolves to the
/// right coin-type / HRP / unit / endpoint, and mainnet can never be confused with a testnet.
/// Bundled networks: Bitcoin mainnet (`0'`) + L2L Signet (`1'`).
final class NetworkRegistryTests: XCTestCase {

    func testCoinTypeMainnetIsZeroTestnetsAreOne() {
        XCTAssertEqual(NetworkRegistry.params(for: .bitcoin).coinType, Int32(0))
        XCTAssertEqual(NetworkRegistry.params(for: .signet).coinType, Int32(1))
    }

    func testMainnetAndTestnetCoinTypesNeverCollide() {
        XCTAssertNotEqual(NetworkRegistry.params(for: .bitcoin).coinType,
                          NetworkRegistry.params(for: .signet).coinType)
    }

    func testAddressHRP() {
        XCTAssertEqual(NetworkRegistry.params(for: .bitcoin).addressHRP, "bc")
        XCTAssertEqual(NetworkRegistry.params(for: .signet).addressHRP, "tb")
    }

    func testUnitLabel() {
        XCTAssertEqual(NetworkRegistry.params(for: .bitcoin).unitLabel, "BTC")
        XCTAssertEqual(NetworkRegistry.params(for: .signet).unitLabel, "sBTC")
    }

    func testSignetDefaultBackend() {
        // L2L drivechain signet electrs (TLS). Must be an SSL Electrum endpoint (the wallet talks
        // Electrum, and we don't ship plaintext by default).
        let backend = NetworkRegistry.params(for: .signet).defaultBackend
        XCTAssertEqual(backend, "ssl://node.signet.drivechain.info:50002")
        XCTAssertTrue(backend.hasPrefix("ssl://"))
    }

    func testExplorerURLSubstitutesTxid() {
        let url = NetworkRegistry.explorerURL(for: "abc123", on: .signet)
        XCTAssertEqual(url, "https://explorer.signet.drivechain.info/tx/abc123")
        XCTAssertFalse(url.contains("{txid}"))
    }

    func testIsMainnet() {
        XCTAssertTrue(WalletNetwork.bitcoin.isMainnet)
        XCTAssertFalse(WalletNetwork.signet.isMainnet)
        // eCash (drynet2) is a TEST chain despite mainnet-style `bc` addresses — must NOT be
        // treated as mainnet (drives the non-mainnet safety chip, Golden Rule §6).
        XCTAssertFalse(WalletNetwork.ecash.isMainnet)
    }

    // MARK: - eCash (drynet2)

    func testEcashParams() {
        let p = NetworkRegistry.params(for: .ecash)
        // Byte-identical to Bitcoin: coin-type 0', `bc` HRP. Unit label is ECX.
        XCTAssertEqual(p.coinType, Int32(0))
        XCTAssertEqual(p.addressHRP, "bc")
        XCTAssertEqual(p.unitLabel, "ECX")
        XCTAssertEqual(p.displayName, "Drynet2")
    }

    func testEcashDefaultBackendIsEsploraAtRootPath() {
        let p = NetworkRegistry.params(for: .ecash)
        // Default backend is the public Esplora (mempool-electrs). The wallet must default to the
        // esplora kind (not electrum), and the URL must NOT carry an `/api` suffix — this instance
        // serves the REST API at the root path (verified live). A trailing `/api` would 404 BDK.
        XCTAssertEqual(p.defaultBackend, "https://esplora.drynet2.drivechain.dev")
        XCTAssertEqual(p.defaultBackendKind, "esplora")
        XCTAssertTrue(p.defaultBackend.hasPrefix("https://"))
        XCTAssertFalse(p.defaultBackend.hasSuffix("/api"))
    }

    func testEcashExplorerSubstitutesTxid() {
        let url = NetworkRegistry.explorerURL(for: "abc123", on: .ecash)
        XCTAssertEqual(url, "https://explorer.drynet2.drivechain.dev/tx/abc123")
        XCTAssertFalse(url.contains("{txid}"))
    }

    /// eCash shares Bitcoin's derivation/addressing (it IS a Bitcoin hardfork) — same coin-type and
    /// HRP — and is separated ONLY by its backend endpoint. This invariant is what lets it map to
    /// BDK `Network.bitcoin`; if it ever drifts, the mapping in `BDKSeam` must be revisited.
    func testEcashIsByteIdenticalToBitcoinButDiffersByBackend() {
        let btc = NetworkRegistry.params(for: .bitcoin)
        let ecx = NetworkRegistry.params(for: .ecash)
        XCTAssertEqual(ecx.coinType, btc.coinType)
        XCTAssertEqual(ecx.addressHRP, btc.addressHRP)
        XCTAssertNotEqual(ecx.defaultBackend, btc.defaultBackend)
    }

    /// The BIP84 account path for an eCash wallet must be the mainnet-coin-type path `m/84'/0'/0'`
    /// (same as Bitcoin) — a true dry-run of eCash mainnet derivation.
    func testEcashDescriptorPathUsesCoinTypeZero() {
        // Spell the enum type explicitly — Skip's transpiler can't infer the owning type for a
        // bare `.ecash` here (internal `Descriptors` helper).
        XCTAssertEqual(Descriptors.accountPath(for: WalletNetwork.ecash), "m/84'/0'/0'")
        XCTAssertEqual(Descriptors.accountPath(for: WalletNetwork.ecash),
                       Descriptors.accountPath(for: WalletNetwork.bitcoin))
    }
}
