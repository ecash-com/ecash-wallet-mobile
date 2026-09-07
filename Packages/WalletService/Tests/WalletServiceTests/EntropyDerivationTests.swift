// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import Foundation
@testable import WalletService

/// The paranoid-mode derivation (`docs/user-provided-entropy.md` §4).
///
/// **The vectors below were computed OUTSIDE this codebase**, with
/// `printf '%s' '<field>' | shasum -a 256`, so these tests are an independent check rather than a
/// restatement of the implementation. That matters more than usual here: the derivation is the
/// promise we make to a user who does not trust our binary, and it must stay verifiable from a shell
/// forever. If one of these fails, either the derivation changed — which silently breaks every user's
/// ability to reproduce their wallet from a saved string — or the hashing is wrong.
final class EntropyDerivationTests: XCTestCase {

    private let systemHex = "7d5c3b1a9e8f0d2c4b6a8e0f1d3c5b7a9e8f0d2c4b6a8e0f1d3c5b7a9e8f0d2c"
    private let timestamp: Int64 = 1_750_000_000_000
    private let userInput = "ABC123"

    private func field(wordCount: Int, systemHex: String? = nil, userInput: String? = nil) -> String {
        EntropyDerivation.field(wordCount: wordCount,
                                systemHex: systemHex ?? self.systemHex,
                                timestampMillis: timestamp,
                                userInput: userInput ?? self.userInput)
    }

    // MARK: - Field shape

    func testFieldIsTheDocumentedFormat() {
        XCTAssertEqual(field(wordCount: 12),
                       "v1&12&\(systemHex)&1750000000000&ABC123")
    }

    /// In user-only mode the CSPRNG component is empty, leaving an empty field between separators —
    /// that is intentional and must stay stable, because it is part of what gets hashed.
    func testUserOnlyFieldHasAnEmptySystemComponent() {
        XCTAssertEqual(field(wordCount: 12, systemHex: ""), "v1&12&&1750000000000&ABC123")
    }

    // MARK: - Golden vectors (independently computed)

    func testTwelveWordEntropyMatchesTheIndependentVector() {
        XCTAssertEqual(EntropyDerivation.entropyHex(field: field(wordCount: 12), wordCount: 12),
                       "b27408a8da3df9ff7e3ca683c3be5fb7")
    }

    func testTwentyFourWordEntropyMatchesTheIndependentVector() {
        XCTAssertEqual(EntropyDerivation.entropyHex(field: field(wordCount: 24), wordCount: 24),
                       "4eb5ee883b4a07b2d94a22bfbcf48ec889cae3e04e0edba005469fa148d48915")
    }

    func testUserOnlyFieldMatchesTheIndependentVector() {
        XCTAssertEqual(
            EntropyDerivation.entropyHex(field: field(wordCount: 12, systemHex: ""), wordCount: 12),
            "9e8ce69dec6371c92778cbbf7d551bb0")
    }

    // MARK: - Domain separation

    /// **The property the whole field format exists for.** With a bare `SHA-256(input)`, 12-word
    /// entropy would be a *prefix* of the 24-word entropy from the same input, so a user who made both
    /// from one string would have a 256-bit wallet worth 128 bits. Because the field carries the word
    /// count, the two digests are unrelated instead.
    func testTwelveWordEntropyIsNotAPrefixOfTwentyFourWord() {
        let twelve = EntropyDerivation.entropyHex(field: field(wordCount: 12), wordCount: 12)
        let twentyFour = EntropyDerivation.entropyHex(field: field(wordCount: 24), wordCount: 24)
        XCTAssertNotNil(twelve)
        XCTAssertNotNil(twentyFour)
        XCTAssertFalse(twentyFour!.hasPrefix(twelve!),
                       "12-word entropy must not be a prefix of 24-word entropy from the same input")
    }

    // MARK: - Sizes

    func testEntropyLengthMatchesTheWordCount() {
        XCTAssertEqual(EntropyDerivation.entropy(field: field(wordCount: 12), wordCount: 12)?.count, 16)
        XCTAssertEqual(EntropyDerivation.entropy(field: field(wordCount: 24), wordCount: 24)?.count, 32)
        XCTAssertEqual(EntropyDerivation.entropyByteCount(wordCount: 12), 16)
        XCTAssertEqual(EntropyDerivation.entropyByteCount(wordCount: 24), 32)
    }

    func testUnsupportedWordCountsAreRefused() {
        XCTAssertNil(EntropyDerivation.entropyByteCount(wordCount: 15))
        XCTAssertNil(EntropyDerivation.entropy(field: field(wordCount: 15), wordCount: 15))
    }

    // MARK: - Validation

    /// The field must carry the word count it is being derived for. Deriving a 24-word wallet from a
    /// field that says `v1&12&…` would produce entropy with none of the domain separation above, so it
    /// is refused rather than quietly allowed.
    func testFieldMustCarryTheWordCountItIsDerivedFor() {
        XCTAssertNil(EntropyDerivation.entropy(field: field(wordCount: 12), wordCount: 24))
        XCTAssertNil(EntropyDerivation.entropy(field: field(wordCount: 24), wordCount: 12))
    }

    func testMalformedFieldsAreRefused() {
        XCTAssertNil(EntropyDerivation.entropy(field: "", wordCount: 12))
        XCTAssertNil(EntropyDerivation.entropy(field: "nonsense", wordCount: 12))
        XCTAssertNil(EntropyDerivation.entropy(field: "v2&12&&0&ABC", wordCount: 12))   // wrong version
    }

    // MARK: - Determinism

    func testDerivationIsDeterministic() {
        let once = EntropyDerivation.entropyHex(field: field(wordCount: 24), wordCount: 24)
        let twice = EntropyDerivation.entropyHex(field: field(wordCount: 24), wordCount: 24)
        XCTAssertEqual(once, twice)
    }

    /// One character of difference must change the whole output — the user needs to be able to trust
    /// that re-entering their string exactly is what reproduces the wallet.
    func testASingleCharacterChangesEverything() {
        let a = EntropyDerivation.entropyHex(field: field(wordCount: 12, userInput: "ABC123"), wordCount: 12)
        let b = EntropyDerivation.entropyHex(field: field(wordCount: 12, userInput: "ABC124"), wordCount: 12)
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
    }

    /// The alphabet is ASCII-only precisely so this cannot happen, but the derivation hashes UTF-8
    /// bytes, so pin that two different byte sequences never collide through some normalisation.
    func testHashingIsOverRawUTF8Bytes() {
        let plain = EntropyDerivation.entropyHex(field: field(wordCount: 12, userInput: "e"), wordCount: 12)
        let accented = EntropyDerivation.entropyHex(field: field(wordCount: 12, userInput: "é"), wordCount: 12)
        XCTAssertNotEqual(plain, accented)
    }

    // MARK: - Hex

    func testHexEncoding() {
        // Via a typed array, not `Data([literal])` — that overload is unavailable in Skip
        // ("constructor(buffer: Any): Data is deprecated").
        // Explicit UInt8() casts: Kotlin infers Int for bare literals and rejects them as UByte
        // (CLAUDE.md §5 — "unsigned literals need explicit casts").
        let bytes = [UInt8(0x00), UInt8(0x0f), UInt8(0xa5), UInt8(0xff)]
        XCTAssertEqual(EntropyDerivation.hex(Data(bytes)), "000fa5ff")
        XCTAssertEqual(EntropyDerivation.hex(Data([UInt8]())), "")
    }
}
