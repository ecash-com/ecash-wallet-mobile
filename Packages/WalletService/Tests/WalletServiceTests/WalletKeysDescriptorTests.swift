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
}
#endif
