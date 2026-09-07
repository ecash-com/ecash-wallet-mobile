// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Entropy the user generated **off-device** and typed in — dice, coin flips, hex.
///
/// **The problem this solves.** For a swipe we observe gestures, timing and run lengths, so we know
/// something about how the input was produced. For typed text we know *nothing*: the same forty
/// characters could be forty dice rolls or a line from a book, and the string alone cannot tell us
/// which. Crediting typed characters at some flat "random-looking" rate would be exactly the
/// swipe-adjacency trap in a new place (`docs/user-provided-entropy.md` §2).
///
/// **So the user declares the source and we do honest arithmetic on the declaration.** That turns the
/// unanswerable question — "is this string random?" — into an answerable one: "how many of what kind of
/// draws does the user say this is?" It also gives a dice user the number they actually want: fifty d6
/// rolls is 129 bits, so fifty rolls is enough for twelve words.
///
/// Three rules keep the declaration meaningful rather than decorative:
/// 1. Input is **restricted to the declared alphabet** (`accepts`), so the credit always matches what
///    was actually entered — a "dice" entry containing `k` is refused at the keystroke.
/// 2. The structural checks still apply. `111111…` is not fifty dice rolls no matter what is declared.
/// 3. Free text is credited **punitively**, because a human-invented "random" string carries far less
///    than it looks like — and anyone with a genuinely good source can declare it and be credited
///    honestly instead.
enum TypedEntropySource: String, CaseIterable, Equatable {
    case diceD6
    case coinFlip
    case hex
    case freeText

    /// Bits per accepted character.
    var bitsPerCharacter: Double {
        switch self {
        case .diceD6: return 2.5849625007211562   // log2(6)
        case .coinFlip: return 1.0
        case .hex: return 4.0
        // Deliberately punitive: a string a human invented is worth far less than its length suggests,
        // and we have no way to tell it from a good one. 128 characters for a 12-word wallet.
        case .freeText: return 1.0
        }
    }

    /// Characters this source accepts. Input outside the set is rejected rather than silently credited.
    var alphabet: Set<Character> {
        switch self {
        case .diceD6: return Set("123456")
        case .coinFlip: return Set("01HTht")
        case .hex: return Set("0123456789abcdefABCDEF")
        // Every printable ASCII character except space — the same set as the swipe grid.
        case .freeText:
            var out = Set<Character>()
            for scalar in 0x21...0x7E {
                if let unicode = Unicode.Scalar(scalar) { out.insert(Character(unicode)) }
            }
            return out
        }
    }

    /// How many distinct outcomes a single draw from this source can have.
    ///
    /// **Not the same as `alphabet.count`.** A coin has two outcomes but we accept four spellings of
    /// them (`0`/`1`/`H`/`T`), so sizing the structural floor off the alphabet would demand three
    /// distinct characters from a source that can only ever produce two — rejecting every honest coin
    /// sequence.
    var outcomeCount: Int {
        switch self {
        case .diceD6: return 6
        case .coinFlip: return 2
        case .hex: return 16
        case .freeText: return 94
        }
    }

    func accepts(_ character: Character) -> Bool { alphabet.contains(character) }

    /// Keep only the characters this source accepts.
    func filtered(_ input: String) -> String {
        String(input.filter { accepts($0) })
    }

    /// Bits carried by `input`, counting only accepted characters.
    func estimatedBits(for input: String) -> Double {
        Double(filtered(input).count) * bitsPerCharacter
    }

    /// How many characters this source needs to reach `requiredBits`.
    func requiredCharacters(forBits requiredBits: Double) -> Int {
        Int((requiredBits / bitsPerCharacter).rounded(.up))
    }

    /// Whether `input` clears both the bit target and the structural floor.
    ///
    /// The structural part matters as much as the arithmetic: a declared source only bounds the credit
    /// per character, it says nothing about whether the user actually drew independently. `111111…`
    /// passes the bit count and must still be refused.
    func rejectionReason(for input: String, requiredBits: Double) -> EntropyRejection? {
        let accepted = filtered(input)
        let distinct = Set(accepted).count
        // A d6 roll can only ever show 6 faces and a coin 2, so the floor scales with the source's
        // OUTCOMES rather than using the grid's flat 16 (or the alphabet size — see `outcomeCount`).
        // Requiring half the outcomes to appear catches all-ones while passing honest sequences.
        let minDistinct = min(Self.structuralDistinctFloor, max(2, outcomeCount / 2))
        if distinct < minDistinct {
            return .tooFewDistinctCharacters(distinct, minDistinct)
        }
        // NOTE: the swipe path's bigram-share test is deliberately NOT reused here. It is tuned for a
        // 94-cell grid; with only k outcomes there are k² possible bigrams, so a *genuinely random*
        // coin sequence sits at 25% each and any threshold that passed it would also pass strict
        // alternation. These two checks work at any alphabet size instead.
        if let share = dominantCharacterShare(accepted), share > Self.maxCharacterShare {
            return .repetitivePattern      // "111111…" — one outcome dominating
        }
        if isShortPeriodRepetition(accepted) {
            return .repetitivePattern      // "121212…", "123456123456…" — filling the box by pattern
        }
        let bits = estimatedBits(for: input)
        if bits < requiredBits { return .notEnoughBits(bits, requiredBits) }
        return nil
    }

    /// Ceiling on the distinct-character requirement, so a large alphabet doesn't demand an
    /// unreasonable spread.
    private static let structuralDistinctFloor = 16

    /// No single outcome may take more than this share. Honest coin flips sit near 0.5, so this
    /// catches a dominated sequence without punishing a legitimately lopsided run of luck.
    private static let maxCharacterShare = 0.7

    /// Longest repeating period we test for. Someone padding the box types a short cycle, not a long
    /// one; anything longer is indistinguishable from real input at these lengths.
    private static let maxTestedPeriod = 8

    private func dominantCharacterShare(_ input: String) -> Double? {
        let characters = Array(input)
        guard !characters.isEmpty else { return nil }
        var counts: [Character: Int] = [:]
        for character in characters { counts[character, default: 0] += 1 }
        guard let highest = counts.values.max() else { return nil }
        return Double(highest) / Double(characters.count)
    }

    /// Whether the input is just a short cycle repeated — `121212…`, `123456123456…`, `111111…`.
    ///
    /// Alphabet-independent, which is why it replaces the bigram test here: it catches the way a user
    /// actually pads the field, at any outcome count.
    private func isShortPeriodRepetition(_ input: String) -> Bool {
        let characters = Array(input)
        guard characters.count >= 4 else { return false }
        for period in 1...min(Self.maxTestedPeriod, characters.count / 2) {
            var matches = true
            for index in period..<characters.count where characters[index] != characters[index % period] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }
}
