// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// Normalization rules for pasted/typed recovery phrases — every shape a paste can take.
final class MnemonicInputTests: XCTestCase {

    func testNormalizeCollapsesWhitespaceAndLowercases() {
        XCTAssertEqual(MnemonicInput.normalize("  Alpha   beta\nGAMMA\t delta  "),
                       "alpha beta gamma delta")
    }

    func testNormalizeEmptyAndWhitespaceOnly() {
        XCTAssertEqual(MnemonicInput.normalize(""), "")
        XCTAssertEqual(MnemonicInput.normalize("   \n\t "), "")
    }

    func testWordCount() {
        XCTAssertEqual(MnemonicInput.wordCount(""), 0)
        XCTAssertEqual(MnemonicInput.wordCount("one two three"), 3)
        XCTAssertEqual(MnemonicInput.wordCount("one\ntwo\nthree\n"), 3)
    }

    func testValidWordCountsAreTwelveAndTwentyFourOnly() {
        let word = "abandon"
        func phrase(_ n: Int) -> String {
            var words: [String] = []
            for _ in 0..<n { words.append(word) }
            return words.joined(separator: " ")
        }
        XCTAssertTrue(MnemonicInput.hasValidWordCount(phrase(12)))
        XCTAssertTrue(MnemonicInput.hasValidWordCount(phrase(24)))
        XCTAssertFalse(MnemonicInput.hasValidWordCount(phrase(0)))
        XCTAssertFalse(MnemonicInput.hasValidWordCount(phrase(11)))
        XCTAssertFalse(MnemonicInput.hasValidWordCount(phrase(13)))
        XCTAssertFalse(MnemonicInput.hasValidWordCount(phrase(23)))
        XCTAssertFalse(MnemonicInput.hasValidWordCount(phrase(25)))
    }
}
