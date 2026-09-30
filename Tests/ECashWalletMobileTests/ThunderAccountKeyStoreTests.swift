// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

@Suite struct ThunderAccountKeyStoreTests {
    /// An isolated UserDefaults domain per test, removed afterwards — never `.standard`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ThunderAccountKeyStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private let key = RistrettoBip32.PublicKey(point: [UInt8](repeating: 7, count: 32),
                                               chainCode: [UInt8](repeating: 9, count: 32))

    @Test func roundTripsPerWallet() {
        withDefaults { defaults in
            let store = UserDefaultsThunderAccountKeyStore(defaults: defaults)
            #expect(store.accountKey(walletId: "w1") == nil)
            store.setAccountKey(key, walletId: "w1")
            #expect(UserDefaultsThunderAccountKeyStore(defaults: defaults).accountKey(walletId: "w1") == key)
            #expect(store.accountKey(walletId: "w2") == nil)
        }
    }

    @Test func forgetRemovesOnlyThatWallet() {
        withDefaults { defaults in
            let store = UserDefaultsThunderAccountKeyStore(defaults: defaults)
            store.setAccountKey(key, walletId: "w1")
            store.setAccountKey(key, walletId: "w2")
            store.forget(walletId: "w1")
            #expect(store.accountKey(walletId: "w1") == nil)
            #expect(store.accountKey(walletId: "w2") == key)
        }
    }

    /// The stored xpub equals the one derived from the seed — the watch-only path and the signing
    /// path can never disagree about which addresses the wallet owns.
    @Test func storedKeyDerivesTheWalletsAddresses() throws {
        let wallet = ThunderWallet(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let account = try wallet.accountPublicKey()
        let viaPublic = try ThunderWallet.addresses(account: account, indices: 0..<5)
        #expect(viaPublic == (try wallet.addresses(indices: 0..<5)))
        for (index, address) in viaPublic.enumerated() {
            #expect(try wallet.key(at: UInt32(index)).address == address)
        }
    }
}
