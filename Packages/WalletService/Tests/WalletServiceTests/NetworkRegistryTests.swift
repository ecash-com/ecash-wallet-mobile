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

    /// The smallest-unit label is eCash-only: "szat" there, "sat" on the Bitcoin-family networks.
    /// Asserted as a pair because the failure that matters is the two BLEEDING into each other —
    /// labelling a Bitcoin fee "szat/vB", or an eCash fee "sat/vB", borrows one chain's unit for
    /// another chain's money (Golden Rule §6, the same confusion the network chip prevents).
    func testSubUnitLabelIsECashOnly() {
        XCTAssertEqual(NetworkRegistry.params(for: .bitcoin).subUnitLabel, "sat")
        XCTAssertEqual(NetworkRegistry.params(for: .signet).subUnitLabel, "sat")
        XCTAssertEqual(NetworkRegistry.params(for: .ecash).subUnitLabel, "szat")
        // Thunder holds eCash value deposited from the eCash mainchain, so it inherits the unit.
        XCTAssertEqual(NetworkRegistry.params(for: .thunder).subUnitLabel, "szat")
    }

    /// Thunder's default backend is a **drivechain-esplora index**, not the node's own JSON-RPC.
    /// The kind is what picks the wire layer app-side (`ThunderBackendFactory`), so a silent drift back
    /// to "thunder" would send Esplora-shaped expectations at a JSON-RPC server, and the reverse.
    func testThunderDefaultsToTheEsploraIndex() {
        let params = NetworkRegistry.params(for: WalletNetwork.thunder)
        XCTAssertEqual(params.defaultBackendKind, "thunder-esplora")
        XCTAssertEqual(params.defaultBackend, "https://seed.alpha.ecash.eu.com/thunder")
        // The index mounts its routes at this base, so a trailing slash would break every route.
        XCTAssertFalse(params.defaultBackend.hasSuffix("/"))
        // Whatever the endpoint, the wallet must accept its own default.
        XCTAssertTrue(BackendURLValidator.isAcceptable(kind: params.defaultBackendKind,
                                                       url: params.defaultBackend))
    }

    /// Both Thunder wire kinds must survive the string round-trip `resolvedBackend` puts them through:
    /// a kind `WalletBackend.Kind.from` doesn't recognise makes a user's Settings override silently
    /// fall through to the bundled default instead of being honoured.
    func testBothThunderBackendKindsParse() {
        XCTAssertEqual(WalletBackend.Kind.from("thunder"), WalletBackend.Kind.thunder)
        XCTAssertEqual(WalletBackend.Kind.from("thunder-esplora"), WalletBackend.Kind.thunderEsplora)
        XCTAssertEqual(WalletBackend.Kind.thunderEsplora.rawValue, "thunder-esplora")
        XCTAssertNil(WalletBackend.Kind.from("thunder-rpc"))
    }

    /// Every network a user can reach in Settings must resolve to a backend kind the app can parse.
    ///
    /// This is the silent-failure guard: `resolvedBackend` runs each override through
    /// `WalletBackend.Kind.from`, and a kind it doesn't recognise makes a user's saved endpoint fall
    /// through to the bundled default with no error — a setting that looks saved and isn't. It also
    /// covers `NetworkEndpointEditor`, which offers Electrum/Esplora or the two Thunder kinds by
    /// switching on `defaultBackendKind.hasPrefix("thunder")`: whichever branch a network takes, the
    /// kind it starts on has to be one the picker can actually represent.
    func testEverySelectableNetworkResolvesToAParseableBackendKind() {
        for network in WalletNetwork.selectable {
            let kind = NetworkRegistry.params(for: network).defaultBackendKind
            XCTAssertNotNil(WalletBackend.Kind.from(kind), "\(network) has an unparseable kind \(kind)")
            XCTAssertTrue(BackendURLValidator.isAcceptable(kind: kind,
                                                           url: NetworkRegistry.params(for: network).defaultBackend),
                          "\(network) ships a default endpoint its own validator rejects")
        }
    }

    /// Thunder is the ONLY network served by something other than BDK — asserted over `allCases`, not
    /// `selectable`, so it holds whether or not Thunder is currently shown in the pickers (a product
    /// decision that has flipped more than once). The split itself is load-bearing: `WalletFacade`
    /// routes on it, and the four BDK call sites that switch on backend kind treat a Thunder endpoint
    /// as unreachable-by-construction rather than something to hand an Electrum/Esplora client.
    func testThunderIsTheOnlyNonBDKNetwork() {
        let nonBDK = WalletNetwork.allCases.filter {
            NetworkRegistry.params(for: $0).defaultBackendKind.hasPrefix("thunder")
        }
        XCTAssertEqual(nonBDK, [WalletNetwork.thunder])
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
        // eCash (drynet3) is a TEST chain despite mainnet-style `bc` addresses — must NOT be
        // treated as mainnet (drives the non-mainnet safety chip, Golden Rule §6).
        XCTAssertFalse(WalletNetwork.ecash.isMainnet)
    }

    // MARK: - eCash (drynet3)

    func testEcashParams() {
        let p = NetworkRegistry.params(for: .ecash)
        // Byte-identical to Bitcoin: coin-type 0', `bc` HRP. Unit label is ECX.
        XCTAssertEqual(p.coinType, Int32(0))
        XCTAssertEqual(p.addressHRP, "bc")
        XCTAssertEqual(p.unitLabel, "ECX")
        XCTAssertEqual(p.displayName, "Drynet3")
    }

    func testEcashDefaultBackendIsEsploraAtRootPath() {
        let p = NetworkRegistry.params(for: .ecash)
        // Default backend is the public Esplora (mempool-electrs). The wallet must default to the
        // esplora kind (not electrum), and the URL must NOT carry an `/api` suffix — this instance
        // serves the REST API at the root path (verified live). A trailing `/api` would 404 BDK.
        XCTAssertEqual(p.defaultBackend, "https://esplora.drynet3.drivechain.dev")
        XCTAssertEqual(p.defaultBackendKind, "esplora")
        XCTAssertTrue(p.defaultBackend.hasPrefix("https://"))
        XCTAssertFalse(p.defaultBackend.hasSuffix("/api"))
    }

    func testEcashExplorerSubstitutesTxid() {
        let url = NetworkRegistry.explorerURL(for: "abc123", on: .ecash)
        XCTAssertEqual(url, "https://explorer.drynet3.drivechain.dev/tx/abc123")
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

    // MARK: - Replay protection (eCash)

    /// eCash stamps the reserved marker `LOCKTIME_THRESHOLD - 1`, which its patched consensus treats
    /// as final while stock Bitcoin Core reads it as a block height ~9,500 years out and rejects the
    /// tx as non-final — so an eCash spend can never replay onto BTC at the same (byte-identical)
    /// addresses. (LayerTwo-Labs/bitcoin-patched#24)
    func testEcashReplayProtectionUsesTheReservedMarker() {
        XCTAssertEqual(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.ecash), UInt32(499_999_999))
    }

    /// The marker must stay BELOW `LOCKTIME_THRESHOLD` (500,000,000): at or above it, Bitcoin reads
    /// nLockTime as a Unix timestamp — a moment in 1985 — which is already past, making the tx final
    /// on Bitcoin too and destroying the protection.
    func testMarkerIsInterpretedAsAHeightNotATimestamp() {
        // `?? UInt32(0)` explicitly — a bare `0` transpiles to a Kotlin Int and the comparison
        // fails to type-check against UInt.
        let marker = NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.ecash) ?? UInt32(0)
        XCTAssertLessThan(marker, UInt32(500_000_000))
    }

    /// Stamping this on Bitcoin or Signet would make their transactions unminable, so those networks
    /// must never carry it.
    func testOnlyEcashStampsALocktime() {
        XCTAssertNil(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.bitcoin))
        XCTAssertNil(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.signet))
        XCTAssertNil(NetworkRegistry.replayProtectionLockHeight(for: WalletNetwork.thunder))
    }

    /// The half that's easy to lose: Bitcoin only ENFORCES nLockTime when an input is non-final.
    /// If this sequence ever became 0xFFFFFFFF, Core would ignore the marker entirely and eCash
    /// spends would replay onto Bitcoin — with nothing else in the code looking any different.
    func testReplayProtectionSequenceIsNonFinal() {
        XCTAssertLessThan(NetworkRegistry.replayProtectionSequence, UInt32(0xFFFF_FFFF))
        XCTAssertEqual(NetworkRegistry.replayProtectionSequence, UInt32(0xFFFF_FFFD))   // BDK's RBF value
    }
}
