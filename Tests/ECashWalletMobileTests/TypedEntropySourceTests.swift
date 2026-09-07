// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// Typed entropy from declared off-device sources (`docs/user-provided-entropy.md` §6.2b).
///
/// The declaration is the whole mechanism: for typed text we observe nothing about provenance, so we
/// credit what the user *says* they drew and then make that declaration binding — the alphabet is
/// restricted to match, and the structural checks still apply. The load-bearing test is
/// `allOnesIsRejectedEvenThoughItIsDeclaredAsDice`: declaring a source must not let obviously
/// non-random input through.
@Suite struct TypedEntropySourceTests {

    // MARK: - Rates

    @Test func creditMatchesTheDeclaredSource() {
        #expect(abs(TypedEntropySource.diceD6.bitsPerCharacter - 2.5849625) < 0.0001)  // log2(6)
        #expect(TypedEntropySource.coinFlip.bitsPerCharacter == 1.0)
        #expect(TypedEntropySource.hex.bitsPerCharacter == 4.0)
    }

    /// Free text is credited punitively on purpose: a string a human invented carries far less than its
    /// length suggests, and we cannot tell it from a good one. Anyone with a real source declares it
    /// and gets honest credit instead.
    @Test func freeTextIsCreditedNoBetterThanACoinFlip() {
        #expect(TypedEntropySource.freeText.bitsPerCharacter
                <= TypedEntropySource.coinFlip.bitsPerCharacter)
    }

    /// The numbers a user actually asks for: "how many dice do I need?"
    @Test func requiredCountsMatchTheDocumentedTargets() {
        #expect(TypedEntropySource.diceD6.requiredCharacters(forBits: 128) == 50)
        #expect(TypedEntropySource.diceD6.requiredCharacters(forBits: 256) == 100)
        #expect(TypedEntropySource.coinFlip.requiredCharacters(forBits: 128) == 128)
        #expect(TypedEntropySource.coinFlip.requiredCharacters(forBits: 256) == 256)
        #expect(TypedEntropySource.hex.requiredCharacters(forBits: 128) == 32)
        #expect(TypedEntropySource.hex.requiredCharacters(forBits: 256) == 64)
        #expect(TypedEntropySource.freeText.requiredCharacters(forBits: 128) == 128)
    }

    // MARK: - Alphabets

    /// The restriction is what makes the declaration binding: credit can only ever be given for
    /// characters the declared source could actually have produced.
    @Test func inputIsRestrictedToTheDeclaredAlphabet() {
        #expect(TypedEntropySource.diceD6.accepts("4"))
        #expect(!TypedEntropySource.diceD6.accepts("7"))
        #expect(!TypedEntropySource.diceD6.accepts("k"))
        #expect(TypedEntropySource.coinFlip.accepts("H"))
        #expect(!TypedEntropySource.coinFlip.accepts("2"))
        #expect(TypedEntropySource.hex.accepts("f"))
        #expect(!TypedEntropySource.hex.accepts("g"))
    }

    @Test func charactersOutsideTheAlphabetAreNotCredited() {
        // Only the four dice faces count; the letters are dropped rather than paid for.
        #expect(TypedEntropySource.diceD6.filtered("1a2b3c4d") == "1234")
        let bits = TypedEntropySource.diceD6.estimatedBits(for: "1a2b3c4d")
        #expect(abs(bits - 4 * 2.5849625) < 0.001)
    }

    /// Free text takes the same 94-character grid alphabet, and nothing outside it.
    @Test func freeTextTakesThePrintableASCIISet() {
        #expect(TypedEntropySource.freeText.alphabet.count == 94)
        #expect(TypedEntropySource.freeText.accepts("!"))
        #expect(TypedEntropySource.freeText.accepts("~"))
        #expect(!TypedEntropySource.freeText.accepts(" "))
        #expect(!TypedEntropySource.freeText.accepts("é"))
    }

    // MARK: - The trap

    /// **A declared source bounds the credit per character; it says nothing about whether the user
    /// actually drew independently.** Fifty `1`s satisfies the arithmetic for a 12-word wallet and must
    /// still be refused.
    @Test func allOnesIsRejectedEvenThoughItIsDeclaredAsDice() {
        let input = String(repeating: "1", count: 60)
        #expect(TypedEntropySource.diceD6.estimatedBits(for: input) >= 128)   // arithmetic satisfied…
        #expect(TypedEntropySource.diceD6.rejectionReason(for: input, requiredBits: 128) != nil)
    }

    /// Padding the box with a repeated cycle must fail at any period, and for any source — this is how
    /// a user actually fakes it, and it is alphabet-independent so one check covers every source.
    @Test func shortPeriodPaddingIsRejected() {
        // Patterns chosen to clear the distinct-outcome floor, so it is periodicity being tested and
        // not the earlier check: "123123…" has 3 distinct faces, "123456…" all 6, "01…" both sides.
        #expect(TypedEntropySource.diceD6.rejectionReason(
            for: String(repeating: "123", count: 30), requiredBits: 128) == .repetitivePattern)
        #expect(TypedEntropySource.diceD6.rejectionReason(
            for: String(repeating: "123456", count: 20), requiredBits: 128) == .repetitivePattern)
        #expect(TypedEntropySource.coinFlip.rejectionReason(
            for: String(repeating: "01", count: 80), requiredBits: 128) == .repetitivePattern)
    }

    /// Two-face padding is refused too — by the distinct-outcome floor rather than periodicity, since
    /// that check runs first. Either reason is correct; what matters is that it does not get through.
    @Test func twoFacePaddingIsRejected() {
        #expect(TypedEntropySource.diceD6.rejectionReason(
            for: String(repeating: "12", count: 40), requiredBits: 128) != nil)
    }

    /// One outcome dominating is refused even when the sequence is not periodic.
    @Test func aDominatedSequenceIsRejected() {
        let input = String(repeating: "1", count: 90) + "23456132456"
        #expect(TypedEntropySource.diceD6.rejectionReason(
            for: input, requiredBits: 128) == .repetitivePattern)
    }

    /// The structural floor has to scale with the source. A d6 can only ever show six faces and a coin
    /// two, so the grid's flat "16 distinct" would make those sources impossible — and the grid's
    /// bigram test is meaningless at k=2, where a genuinely random sequence sits at 25% per bigram.
    @Test func anHonestCoinSequenceIsAccepted() {
        // A coin can only produce two symbols; requiring 16 would reject every honest coin sequence.
        let flips = "0110100110010110100101100110100101101001100101100110100110010110"
            + "1001011001101001011010011001011001101001100101101001011001101001"
        #expect(TypedEntropySource.coinFlip.rejectionReason(for: flips, requiredBits: 128) == nil)
    }

    // MARK: - Acceptance

    @Test func aGenuineDiceSequenceIsAccepted() {
        // 60 varied d6 rolls ≈ 155 bits.
        let rolls = "351426134562513462415326145362431562134526413526145362415326413526"
        #expect(TypedEntropySource.diceD6.rejectionReason(for: rolls, requiredBits: 128) == nil)
    }

    @Test func tooFewRollsIsReportedWithTheShortfall() {
        let rolls = "351426134562513462"   // 18 rolls ≈ 46 bits
        guard case .notEnoughBits(let got, let needed)? =
                TypedEntropySource.diceD6.rejectionReason(for: rolls, requiredBits: 128) else {
            Issue.record("expected a not-enough-bits rejection"); return
        }
        #expect(got < needed)
        #expect(needed == 128)
    }

    @Test func twentyFourWordsNeedsTwiceTheRolls() {
        let rolls = "351426134562513462415326145362431562134526413526145362415326413526"
        #expect(TypedEntropySource.diceD6.rejectionReason(for: rolls, requiredBits: 128) == nil)
        #expect(TypedEntropySource.diceD6.rejectionReason(for: rolls, requiredBits: 256) != nil)
    }
}
