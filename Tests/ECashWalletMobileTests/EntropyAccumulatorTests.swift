// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The entropy accounting — the actual security mechanism of paranoid mode
/// (`docs/user-provided-entropy.md` §2, §6).
///
/// The test that matters most here is `aLazyBackAndForthSwipeIsRejectedDespiteEnoughBits`: it encodes
/// the trap the whole design exists to avoid. A user sweeping side to side produces a
/// plausible-looking string from a tiny corner of the grid, sails past the bit counter, and would get
/// a grindable wallet. The structural checks, not the counter, are what stop it.
@Suite struct EntropyAccumulatorTests {

    /// Feed a string as one gesture (or mark gesture starts by index).
    private func accumulator(_ input: String, gestureStarts: Set<Int> = [0]) -> EntropyAccumulator {
        var accumulator = EntropyAccumulator()
        for (index, character) in input.enumerated() {
            accumulator.record(character, startsGesture: gestureStarts.contains(index))
        }
        return accumulator
    }

    // MARK: - Runs

    @Test func repeatsCollapseIntoRuns() {
        let accumulator = accumulator("AAABBBBCC")
        let runs = accumulator.runs()
        #expect(runs.count == 3)
        #expect(runs.map(\.character) == ["A", "B", "C"])
        #expect(runs.map(\.length) == [3, 4, 2])
    }

    /// The recorded string keeps the repeats — it is a faithful record of the gesture, and it is what
    /// gets hashed. Only the *accounting* collapses them.
    @Test func theRecordedStringKeepsItsRepeats() {
        #expect(accumulator("AAABBBBCC").userInput == "AAABBBBCC")
    }

    /// A finger parked on one key must not produce a three-thousand-character string, and must stop
    /// earning after the cap.
    @Test func aRunStopsGrowingAtTheCap() {
        var accumulator = EntropyAccumulator()
        accumulator.record("A", startsGesture: true)
        for _ in 0..<100 { accumulator.record("A", startsGesture: false) }
        #expect(accumulator.userInput.count == EntropyAccumulator.maxRunSamples)
    }

    // MARK: - Credit

    /// A run earns for its transition plus, once, for its length — never per sample. Crediting per
    /// sample is the amplified version of the §2 trap: consecutive samples on one key are ~95%
    /// predictable, so a 400-character string could read as ">256 bits" while holding ~60.
    @Test func creditIsPerRunNotPerSample() {
        // One gesture, three runs: first is a touch-down (5.0), the others mid-drag (1.5 each).
        // All three have length > 1, so each also earns 1.0 for dwell.
        let bits = accumulator("AAABBBBCC").estimatedBits()
        #expect(abs(bits - (5.0 + 1.0 + 1.5 + 1.0 + 1.5 + 1.0)) < 0.001)
    }

    @Test func aSingleSampleRunEarnsNoDwellCredit() {
        // Three runs of length 1: touch-down + two mid-drag, no length credit at all.
        let bits = accumulator("ABC").estimatedBits()
        #expect(abs(bits - (5.0 + 1.5 + 1.5)) < 0.001)
    }

    /// A fresh stroke is worth more than continuing one: the touch-down point is uncorrelated with the
    /// previous path, whereas a mid-drag step only reaches a neighbour.
    @Test func aFreshStrokeEarnsMoreThanContinuingOne() {
        let continuous = accumulator("ABCD", gestureStarts: [0]).estimatedBits()
        let strokes = accumulator("ABCD", gestureStarts: [0, 1, 2, 3]).estimatedBits()
        #expect(strokes > continuous)
        #expect(abs(strokes - 4 * EntropyAccumulator.bitsPerTouchDownTransition) < 0.001)
    }

    /// Pinned because §2's analysis says a swipe step is worth ~1.5 bits, and an earlier draft credited
    /// 2.0 — crediting more than the analysis supports is exactly how this feature goes wrong.
    @Test func midDragCreditMatchesTheAdjacencyAnalysis() {
        #expect(EntropyAccumulator.bitsPerMidDragTransition == 1.5)
    }

    // MARK: - The trap

    /// **The test this whole type exists for.** Sweeping back and forth between two keys racks up bits
    /// quickly — 100 runs is 150 bits, past the 12-word target — while using two characters out of 94.
    /// It must be refused.
    @Test func aLazyBackAndForthSwipeIsRejectedDespiteEnoughBits() {
        let input = String(repeating: "AB", count: 50)
        let accumulator = accumulator(input, gestureStarts: [0])
        #expect(accumulator.estimatedBits() >= 128)          // the counter is satisfied…
        #expect(!accumulator.isAcceptable(requiredBits: 128)) // …and it is still refused
    }

    @Test func tooFewDistinctCharactersIsReported() {
        let accumulator = accumulator(String(repeating: "AB", count: 50))
        guard case .tooFewDistinctCharacters(let got, let needed)? =
                accumulator.rejectionReason(requiredBits: 128) else {
            Issue.record("expected a distinct-character rejection"); return
        }
        #expect(got == 2)
        #expect(needed == EntropyAccumulator.minDistinctCharacters)
    }

    /// An oscillating pattern must fail even when it uses plenty of distinct characters.
    @Test func anOscillatingPatternIsRejected() {
        // 20 distinct characters, but every transition is one of two bigrams.
        var input = ""
        for _ in 0..<40 { input += "AZ" }
        for scalar in 0x41...0x54 { input += String(Character(Unicode.Scalar(scalar)!)) }
        let accumulator = accumulator(input, gestureStarts: [0, 1, 2])
        #expect(!accumulator.isAcceptable(requiredBits: 128))
    }

    /// A single unbroken stroke is fine — there is deliberately no minimum-gesture requirement.
    ///
    /// 1.5 bits per transition IS the continuous-stroke rate, derived for mid-drag motion. So a long
    /// single sweep earns at exactly the rate that models it, and demanding lifts protected against
    /// nothing the credit rate does not already handle. Lifting is rewarded (5 bits versus 1.5), not
    /// mandated.
    @Test func aSingleUnbrokenStrokeIsAcceptable() {
        var input = ""
        for _ in 0..<40 { for scalar in 0x41...0x5A { input += String(Character(Unicode.Scalar(scalar)!)) } }
        let accumulator = accumulator(input, gestureStarts: [0])
        #expect(accumulator.rejectionReason(requiredBits: 1000) == nil)
    }

    /// …but it takes longer than the same input broken into strokes, because each touch-down earns
    /// more than a mid-drag step.
    @Test func strokesEarnFasterThanOneContinuousSweep() {
        var input = ""
        for _ in 0..<4 { for scalar in 0x41...0x5A { input += String(Character(Unicode.Scalar(scalar)!)) } }
        let oneStroke = accumulator(input, gestureStarts: [0]).estimatedBits()
        let manyStrokes = accumulator(input, gestureStarts: Set(stride(from: 0, to: 104, by: 26)))
            .estimatedBits()
        #expect(manyStrokes > oneStroke)
    }

    // MARK: - Acceptance

    /// A varied input across several strokes should pass — the checks must not be so strict that
    /// genuine use is impossible.
    @Test func variedInputAcrossSeveralStrokesIsAccepted() {
        let accumulator = accumulator(Self.variedInput, gestureStarts: [0, 26, 52, 78])
        #expect(accumulator.rejectionReason(requiredBits: 128) == nil)
    }

    @Test func twentyFourWordsNeedsMoreThanTwelve() {
        let accumulator = accumulator(Self.variedInput, gestureStarts: [0, 26, 52, 78])
        #expect(accumulator.isAcceptable(requiredBits: 128))
        #expect(!accumulator.isAcceptable(requiredBits: 256))
    }

    /// Four strokes of A–Z: 104 characters ≈ 170 bits. Worth noting that 78 characters lands at
    /// 127.5 — just under the 12-word target — which matches the doc's estimate of ~85 characters for
    /// 128 bits and is a useful sanity check that the rates and the plan agree.
    private static let variedInput: String = {
        var input = ""
        for _ in 0..<4 {
            for scalar in 0x41...0x5A { input += String(Character(Unicode.Scalar(scalar)!)) }
        }
        return input
    }()

    @Test func resetClearsEverything() {
        var accumulator = accumulator("AAABBBCCC")
        accumulator.reset()
        #expect(accumulator.userInput.isEmpty)
        #expect(accumulator.estimatedBits() == 0)
    }
}
