// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

/// The backup verify quiz — correctness of question construction, since a wrong `answer`
/// would brick the user's ability to mark a wallet backed up.
final class BackupVerificationTests: XCTestCase {

    private let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
                         "golf", "hotel", "india", "juliet", "kilo", "lima"]

    func testForcedIndicesProduceOrderedQuestionsWithCorrectAnswers() {
        let plan = BackupVerification.plan(words: words, forcedIndices: [7, 0, 11])
        XCTAssertEqual(plan.map { $0.wordIndex }, [0, 7, 11]) // sorted ascending
        for question in plan {
            XCTAssertEqual(question.answer, words[question.wordIndex])
            XCTAssertTrue(question.choices.contains(question.answer))
            XCTAssertEqual(question.choices.filter { $0 == question.answer }.count, 1)
            XCTAssertEqual(question.choices.count, 3)
            XCTAssertEqual(Set(question.choices).count, question.choices.count) // no dupes
        }
    }

    func testRandomPlanCoversDistinctIndicesWithinRange() {
        let plan = BackupVerification.plan(words: words)
        XCTAssertEqual(plan.count, 3)
        let indices = plan.map { $0.wordIndex }
        XCTAssertEqual(Set(indices).count, indices.count) // distinct questions
        for index in indices {
            XCTAssertTrue(index >= 0 && index < words.count)
        }
        // Sorted ascending so the quiz walks the phrase in order.
        XCTAssertEqual(indices, indices.sorted())
    }

    func testRepeatedWordsYieldFewerChoicesNotDuplicates() {
        // 11 identical words + one distinct — only one valid decoy exists.
        var repeated: [String] = []
        for _ in 0..<11 { repeated.append("same") }
        repeated.append("different")
        let plan = BackupVerification.plan(words: repeated, forcedIndices: [0])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].answer, "same")
        XCTAssertEqual(Set(plan[0].choices).count, plan[0].choices.count)
        XCTAssertTrue(plan[0].choices.contains("same"))
    }

    func testEmptyAndTinyPhrases() {
        XCTAssertTrue(BackupVerification.plan(words: []).isEmpty)
        let tiny = BackupVerification.plan(words: ["one", "two"])
        XCTAssertEqual(tiny.count, 2) // capped at word count
    }

    func testOutOfRangeForcedIndicesAreDropped() {
        let plan = BackupVerification.plan(words: words, forcedIndices: [-1, 5, 99])
        XCTAssertEqual(plan.map { $0.wordIndex }, [5])
    }
}
