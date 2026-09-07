// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// Crediting typed entropy by inferring the alphabet, with no source for the user to declare
/// (`docs/user-provided-entropy.md` §6.2b).
///
/// The declared-source design this replaced was dropped because the declaration never did the security
/// work attributed to it — someone declaring "dice" and mashing 1–6 got the same credit inference
/// gives. The structural checks were always what caught bad input, so those are the tests that matter
/// most here.
@Suite struct TypedEntropyEstimatorTests {

    // MARK: - Inference

    /// The three shapes real off-device sources take, each landing on the right answer with nothing
    /// declared.
    @Test func mechanicalAlphabetsAreCreditedAtTheirCeiling() {
        // 50 d6 rolls -> log2(6) each -> 129 bits
        let dice = "351426134562513462415326145362431562134526413526145362415326"
        #expect(abs(TypedEntropyEstimator.bitsPerCharacter(for: dice) - 2.585) < 0.01)

        let coins = "0110100110010110100101100110100101101001100101100110100110010110"
        #expect(TypedEntropyEstimator.bitsPerCharacter(for: coins) == 1.0)

        let hex = "9f3a2c7e15b804d6af23e9c150d7b48e"
        #expect(TypedEntropyEstimator.bitsPerCharacter(for: hex) == 4.0)
    }

    /// A large alphabet is what human "random" typing looks like, and it is indistinguishable from a
    /// genuinely random paste — so it is credited at the pessimistic rate. Being wrong this way costs
    /// a careful user some typing; being wrong the other way costs someone their coins.
    @Test func largeAlphabetsFallBackToHumanTypingRate() {
        var input = ""
        for scalar in 0x41...0x6A { input += String(Character(Unicode.Scalar(scalar)!)) }   // 42 distinct
        #expect(TypedEntropyEstimator.bitsPerCharacter(for: input)
                == TypedEntropyEstimator.humanTypingBits)
    }

    @Test func aSingleRepeatedSymbolIsWorthNothing() {
        #expect(TypedEntropyEstimator.bitsPerCharacter(for: String(repeating: "7", count: 40)) == 0)
        #expect(TypedEntropyEstimator.estimatedBits(for: String(repeating: "7", count: 40)) == 0)
    }

    // MARK: - Targets

    @Test func realSourcesReachTheirDocumentedCounts() {
        // 50 dice rolls ~ 129 bits; 128 coin flips ~ 128; 32 hex ~ 128.
        let dice = String(repeating: "351426", count: 9)      // 54 chars, 6 distinct
        #expect(TypedEntropyEstimator.estimatedBits(for: dice) >= 128)
        let hex = "9f3a2c7e15b804d6af23e9c150d7b48e"          // 32 chars, 16 distinct
        #expect(TypedEntropyEstimator.estimatedBits(for: hex) >= 128)
    }

    @Test func remainingCountsDownAndNeverJumpsUpwardFromEmpty() {
        // With nothing typed there is no rate yet, so the pessimistic one is quoted — the target must
        // not grow as the user reveals a smaller alphabet.
        let empty = TypedEntropyEstimator.charactersRemaining(for: "", requiredBits: 128)
        #expect(empty == 128)
        let dice = TypedEntropyEstimator.charactersRemaining(for: "351426", requiredBits: 128)
        #expect(dice < empty)
    }

    // MARK: - Alphabet

    @Test func onlyPrintableASCIICounts() {
        #expect(TypedEntropyEstimator.filtered("ab c\u{00e9}d") == "abcd")
        #expect(TypedEntropyEstimator.alphabet.count == 94)
    }

    // MARK: - The structural floor (what actually protects the user)

    @Test func aSingleRepeatedSymbolIsRejected() {
        #expect(TypedEntropyEstimator.rejectionReason(
            for: String(repeating: "1", count: 200), requiredBits: 128) != nil)
    }

    @Test func shortPeriodPaddingIsRejectedAtAnyAlphabetSize() {
        for padding in ["123123", "1212", "abcabc", "01"] {
            let input = String(repeating: padding, count: 40)
            #expect(TypedEntropyEstimator.rejectionReason(for: input, requiredBits: 128) != nil,
                    "\(padding) repeated must be refused")
        }
    }

    @Test func aDominatedSequenceIsRejected() {
        let input = String(repeating: "1", count: 90) + "23456132456"
        #expect(TypedEntropyEstimator.rejectionReason(for: input, requiredBits: 128)
                == .repetitivePattern)
    }

    // MARK: - Acceptance

    @Test func aGenuineDiceSequenceIsAccepted() {
        let rolls = "351426134562513462415326145362431562134526413526145362415326413526"
        #expect(TypedEntropyEstimator.rejectionReason(for: rolls, requiredBits: 128) == nil)
    }

    @Test func aGenuineCoinSequenceIsAccepted() {
        let flips = "0110100110010110100101100110100101101001100101100110100110010110"
            + "1001011001101001011010011001011001101001100101101001011001101001"
        #expect(TypedEntropyEstimator.rejectionReason(for: flips, requiredBits: 128) == nil)
    }

    @Test func twentyFourWordsNeedsMore() {
        let rolls = "351426134562513462415326145362431562134526413526145362415326413526"
        #expect(TypedEntropyEstimator.rejectionReason(for: rolls, requiredBits: 128) == nil)
        #expect(TypedEntropyEstimator.rejectionReason(for: rolls, requiredBits: 256) != nil)
    }
}
