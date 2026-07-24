// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// The PUBLIC descriptors the factory persists must be account-level watch descriptors that
/// match the runtime wallet — and must never contain secret material. Regression for the
/// 2026-06-12 bug where the MASTER tpub was persisted (annotated with the account origin), so
/// the stored descriptor derived addresses the wallet never used. Real-BDK, host-only.
#if !SKIP
final class WalletKeysDescriptorTests: XCTestCase {

    private func makeFactory() -> BDKWalletEngineFactory {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walletkeys-tests-\(UUID().uuidString)", isDirectory: true)
        return BDKWalletEngineFactory(chainDataDirectory: dir)
    }

    func testPublicDescriptorsAreAccountLevelWatchOnly() throws {
        let keys = try makeFactory().create(network: .signet, wordCount: 12)

        for descriptor in [keys.externalDescriptor, keys.internalDescriptor] {
            // No secret material, ever (Golden Rule §2/§7).
            XCTAssertFalse(descriptor.contains("tprv"), "secret key leaked into stored descriptor")
            // Account-level: the origin bracket is immediately followed by the ACCOUNT tpub.
            XCTAssertTrue(descriptor.contains("/84'/1'/0']tpub"),
                          "stored descriptor is not an account-level BIP84 watch descriptor")
            // A depth-0 (master) tpub always carries this base58 prefix — the exact bug shape.
            XCTAssertFalse(descriptor.contains("tpubD6NzVbkrYhZ4"),
                           "stored descriptor wraps the MASTER key, not the account key")
        }
        XCTAssertTrue(keys.externalDescriptor.contains("/0/*"))
        XCTAssertTrue(keys.internalDescriptor.contains("/1/*"))
    }

    func testRestoreReproducesIdenticalDescriptors() throws {
        let factory = makeFactory()
        let created = try factory.create(network: .signet, wordCount: 12)
        let restored = try factory.restore(network: .signet, mnemonic: created.secret)
        XCTAssertEqual(created.externalDescriptor, restored.externalDescriptor)
        XCTAssertEqual(created.internalDescriptor, restored.internalDescriptor)
    }

    // MARK: - Custom derivation (script type) — recovery-correctness for the airdrop

    /// The canonical all-zeros BIP39 vector — its per-script-type mainnet addresses are well-known.
    private static let abandon = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    /// Each script type must derive its OWN, correctly-prefixed first address on `.ecash`
    /// (Network.bitcoin, coin-type 0' — the airdrop case: a BTC seed at `m/8x'/0'/0'`). Anchored to
    /// the standard BIP84 test vector; the others are asserted distinct + prefix-correct.
    func testScriptTypesDeriveDistinctCorrectlyPrefixedAddresses() throws {
        let f = makeFactory()
        func addr(_ t: ScriptType) throws -> String {
            try f.previewAddress(forSeed: Self.abandon, scriptType: t, network: .ecash)
        }
        let legacy = try addr(.bip44)   // 1…
        let nested = try addr(.bip49)   // 3…
        let native = try addr(.bip84)   // bc1q…
        let taproot = try addr(.bip86)  // bc1p…

        // Well-known BIP84 vector for "abandon…about" at m/84'/0'/0'/0/0.
        XCTAssertEqual(native, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        // Correct address kind per script type (proves the right template, not just "different").
        XCTAssertTrue(legacy.hasPrefix("1"), "BIP44 should be P2PKH 1…, got \(legacy)")
        XCTAssertTrue(nested.hasPrefix("3"), "BIP49 should be P2SH 3…, got \(nested)")
        XCTAssertTrue(native.hasPrefix("bc1q"), "BIP84 should be P2WPKH bc1q…, got \(native)")
        XCTAssertTrue(taproot.hasPrefix("bc1p"), "BIP86 should be P2TR bc1p…, got \(taproot)")
        // All four distinct — no silent collapse to one derivation.
        XCTAssertEqual(Set([legacy, nested, native, taproot]).count, 4)
    }

    /// The public descriptor a non-default script type persists must carry that BIP's purpose and no
    /// secret — so the watch-only reload derives the right addresses AND signing (which rebuilds from
    /// `scriptType`) matches. Guards the "receive works, send silently can't sign" seam (§4.2).
    func testNonDefaultScriptTypePersistsMatchingPublicDescriptor() throws {
        let keys = try makeFactory().restore(network: .ecash, mnemonic: Self.abandon, scriptType: .bip44)
        for d in [keys.externalDescriptor, keys.internalDescriptor] {
            XCTAssertTrue(d.contains("/44'/0'/0']") && d.contains("pkh("),
                          "BIP44 descriptor should be pkh at m/44'/0'/0', got \(d)")
            XCTAssertFalse(d.contains("prv"), "secret leaked into stored descriptor")
        }
    }
}
#endif
