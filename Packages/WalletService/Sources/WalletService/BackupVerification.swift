// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// One verify question: "what was word #N?" with tappable choices.
/// Top-level (not nested in BackupVerification) — the bridge generator mishandles nested
/// public types (see the Descriptors gotcha in CLAUDE.md §5 / memory).
public struct BackupQuestion: Equatable, Sendable {
    /// Zero-based index into the phrase; display as "word #\(wordIndex + 1)".
    public let wordIndex: Int
    /// Shuffled choices shown to the user — contains the correct word exactly once.
    public let choices: [String]
    public let answer: String

    public init(wordIndex: Int, choices: [String], answer: String) {
        self.wordIndex = wordIndex
        self.choices = choices
        self.answer = answer
    }
}

/// Builds the backup verify quiz from a revealed phrase. Pure + deterministic when indices are
/// injected (tests); random in production. Decoys are drawn from the OTHER words of the same
/// phrase, so nothing beyond what the reveal screen already showed ever appears on screen.
public enum BackupVerification {
    /// Build `questionCount` questions, each with up to `choiceCount` choices.
    /// `forcedIndices` (tests) pins which word positions are asked, in order; nil = random.
    public static func plan(words: [String],
                            questionCount: Int = 3,
                            choiceCount: Int = 3,
                            forcedIndices: [Int]? = nil) -> [BackupQuestion] {
        if words.isEmpty { return [] }
        let count = min(questionCount, words.count)

        var indices: [Int]
        if let forced = forcedIndices {
            indices = forced.filter { $0 >= 0 && $0 < words.count }
        } else {
            indices = Array(0..<words.count).shuffled()
        }
        indices = Array(indices.prefix(count)).sorted()

        var questions: [BackupQuestion] = []
        for index in indices {
            let answer = words[index]
            // Decoys: distinct other words from the phrase (a phrase with repeated words —
            // possible in BIP39 — just yields fewer choices rather than duplicates).
            var choices: [String] = [answer]
            let others = words.filter { $0 != answer }.shuffled()
            for other in others {
                if choices.count >= choiceCount { break }
                if !choices.contains(other) {
                    choices.append(other)
                }
            }
            questions.append(BackupQuestion(wordIndex: index,
                                            choices: choices.shuffled(),
                                            answer: answer))
        }
        return questions
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
