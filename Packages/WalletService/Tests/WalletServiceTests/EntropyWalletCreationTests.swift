// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Real-BDK tests for the paranoid-mode create path (docs/user-provided-entropy.md). Like
// BDKWalletEngineTests these cross into actual bdk-swift, so they run ONLY on the macOS host and
// XCTSkip under Robolectric where the bdk-android `.so` isn't loaded.
//
// SkipUnit lacks XCTAssertThrowsError and this file still transpiles, so throwing expectations use
// do/catch rather than the XCTAssert* throwing helpers.

import XCTest
import Foundation
@testable import WalletService
#if !SKIP
import BitcoinDevKit
#endif

final class EntropyWalletCreationTests: XCTestCase {

    private func skipOnAndroid() throws {
        #if SKIP
        throw XCTSkip("Real BDK: host-only (bdk-android .so isn't loaded under Robolectric)")
        #endif
    }

    private let systemHex = "7d5c3b1a9e8f0d2c4b6a8e0f1d3c5b7a9e8f0d2c4b6a8e0f1d3c5b7a9e8f0d2c"

    private func field(wordCount: Int, userInput: String = "ABC123") -> String {
        EntropyDerivation.field(wordCount: wordCount, systemHex: systemHex,
                                timestampMillis: 1_750_000_000_000, userInput: userInput)
    }

    // MARK: - BDK's half

    /// The canonical BIP39 vector: 16 zero bytes of entropy is "abandon …× 11… about".
    ///
    /// This pins **BDK's** entropy→words mapping against published ground truth, separately from our
    /// derivation. Splitting it this way means a failure tells you *which* half moved: this test, or
    /// the independently-computed SHA-256 vectors in `EntropyDerivationTests`. It also proves
    /// `Mnemonic.fromEntropy` behaves as the design assumes, so we never hand-roll BIP39 (Golden Rule §1).
    func testBDKMapsTheCanonicalBIP39VectorAsExpected() throws {
        try skipOnAndroid()
        #if !SKIP
        let mnemonic = try Mnemonic.fromEntropy(entropy: Data([UInt8](repeating: 0, count: 16)))
        XCTAssertEqual("\(mnemonic)",
                       "abandon abandon abandon abandon abandon abandon "
                       + "abandon abandon abandon abandon abandon about")

        let long = try Mnemonic.fromEntropy(entropy: Data([UInt8](repeating: 0, count: 32)))
        XCTAssertEqual("\(long)".split(separator: " ").count, 24)
        #endif
    }

    // MARK: - Composition

    func testTwelveWordFieldProducesTwelveWords() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        let keys = try factory.create(network: .signet, entropyField: field(wordCount: 12),
                                      wordCount: 12, scriptType: .bip84)
        XCTAssertEqual(keys.secret.split(separator: " ").count, 12)
        XCTAssertFalse(keys.externalDescriptor.isEmpty)
    }

    func testTwentyFourWordFieldProducesTwentyFourWords() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        let keys = try factory.create(network: .signet, entropyField: field(wordCount: 24),
                                      wordCount: 24, scriptType: .bip84)
        XCTAssertEqual(keys.secret.split(separator: " ").count, 24)
    }

    /// **The promise paranoid mode makes.** The same field must always give the same wallet, or the
    /// user cannot verify anything and cannot reproduce their wallet from a saved string.
    func testTheSameFieldAlwaysProducesTheSameWallet() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        let first = try factory.create(network: .signet, entropyField: field(wordCount: 12),
                                       wordCount: 12, scriptType: .bip84)
        let second = try factory.create(network: .signet, entropyField: field(wordCount: 12),
                                        wordCount: 12, scriptType: .bip84)
        XCTAssertEqual(first.secret, second.secret)
        XCTAssertEqual(first.externalDescriptor, second.externalDescriptor)
    }

    func testOneCharacterOfDifferenceGivesADifferentWallet() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        let a = try factory.create(network: .signet, entropyField: field(wordCount: 12, userInput: "ABC123"),
                                   wordCount: 12, scriptType: .bip84)
        let b = try factory.create(network: .signet, entropyField: field(wordCount: 12, userInput: "ABC124"),
                                   wordCount: 12, scriptType: .bip84)
        XCTAssertNotEqual(a.secret, b.secret)
        XCTAssertNotEqual(a.externalDescriptor, b.externalDescriptor)
    }

    /// The domain separation from §3, proven through to actual wallets rather than just digests.
    func testTwelveAndTwentyFourWordWalletsAreUnrelated() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        let twelve = try factory.create(network: .signet, entropyField: field(wordCount: 12),
                                        wordCount: 12, scriptType: .bip84)
        let twentyFour = try factory.create(network: .signet, entropyField: field(wordCount: 24),
                                            wordCount: 24, scriptType: .bip84)
        // Not merely different phrases: the 12-word entropy must not be embedded in the 24-word one,
        // which is what a bare SHA-256 truncation would have produced.
        XCTAssertNotEqual(twelve.externalDescriptor, twentyFour.externalDescriptor)
        // `{ String($0) }`, not `String.init` — a bare String initializer reference doesn't transpile
        // ("actual type is 'String.Companion'"), the same trap noted in BackendURLValidator.
        let twelveWords = twelve.secret.split(separator: " ").map { String($0) }
        let longWords = twentyFour.secret.split(separator: " ").map { String($0) }
        XCTAssertNotEqual(Array(longWords.prefix(12)), twelveWords)
    }

    /// The produced phrase must be a real BIP39 mnemonic — BDK made it, so it should be, but this is
    /// the property a user relies on when they type it into another wallet.
    func testTheProducedPhraseIsAValidMnemonic() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        let keys = try factory.create(network: .signet, entropyField: field(wordCount: 24),
                                      wordCount: 24, scriptType: .bip84)
        let restored = try factory.restore(network: .signet, mnemonic: keys.secret, scriptType: .bip84)
        XCTAssertEqual(restored.externalDescriptor, keys.externalDescriptor)
    }

    // MARK: - Rejection

    func testMalformedFieldsAreRejected() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        for bad in ["", "nonsense", "v2&12&&0&ABC"] {
            do {
                _ = try factory.create(network: .signet, entropyField: bad, wordCount: 12, scriptType: .bip84)
                XCTFail("expected \(bad) to be rejected")
            } catch let error as WalletError {
                XCTAssertEqual(error, WalletError.invalidEntropy)
            }
        }
    }

    /// A field built for one word count must not be usable at another — that is what carries the
    /// domain separation, so silently allowing it would remove the property.
    func testAWordCountMismatchIsRejected() throws {
        try skipOnAndroid()
        let factory = BDKWalletEngineFactory(chainDataDirectory: FileManager.default.temporaryDirectory)
        do {
            _ = try factory.create(network: .signet, entropyField: field(wordCount: 12),
                                   wordCount: 24, scriptType: .bip84)
            XCTFail("expected a word-count mismatch to be rejected")
        } catch let error as WalletError {
            XCTAssertEqual(error, WalletError.invalidEntropy)
        }
    }

    /// Errors must never carry the entropy or the phrase (Golden Rule §2) — mirrors the scrubbing
    /// assertions in `WalletErrorTests`.
    func testTheErrorLeaksNothing() {
        let message = WalletError.invalidEntropy.userMessage
        XCTAssertFalse(message.contains(systemHex))
        XCTAssertFalse(message.contains("ABC123"))
        XCTAssertFalse(message.lowercased().contains("v1&"))
    }
}
