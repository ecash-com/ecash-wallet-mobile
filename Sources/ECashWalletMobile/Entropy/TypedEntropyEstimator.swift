// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Credits typed entropy without asking the user what kind it is.
///
/// **Why there is no "pick your source" control.** An earlier design had the user declare dice / coin
/// / hex / free text, on the reasoning that we cannot observe provenance for typed text so the
/// declaration made the credit honest. That reasoning was wrong: a user who declares "dice" and then
/// mashes the digits 1–6 gets exactly the credit inference would have given them. The declaration set
/// the alphabet and the target; it never protected against careless input — the **structural checks
/// did, and still do**. So the picker was a question the user had to answer for no security benefit,
/// and it is gone.
///
/// **What replaces it: infer the alphabet from what was actually typed.** The only evidence of how
/// many symbols someone was drawing from is the set they used.
///
/// - **k ≤ 16 distinct symbols** — credit `log2(k)`. A small, constrained alphabet is what a mechanical
///   source looks like, and `log2(k)` is a genuine ceiling there: even a human cannot beat it. Fifty
///   dice rolls come out at 129 bits, 128 coin flips at 128, 32 hex characters at 128 — the right
///   answers, with nothing to declare.
/// - **k > 16** — credit **1 bit** per character. A large alphabet is exactly what human "random"
///   typing looks like, and we cannot distinguish it from a genuinely random paste. Being wrong here
///   costs a careful user some extra typing; being wrong the other way costs someone their coins.
///
/// **The residual risk, stated plainly:** someone mashing hex-ish characters is credited up to 4 bits
/// each when they may be producing 2. The structural checks (§6.3) are what catch that, as they always
/// were, and the meter is an estimate rather than a guarantee — which the screen says out loud.
enum TypedEntropyEstimator {

    /// Above this many distinct symbols we stop believing the input is mechanical.
    static let mechanicalAlphabetCeiling = 16
    /// What a character is worth once the alphabet is too large to be trusted as mechanical.
    static let humanTypingBits = 1.0

    /// Everything the entropy field accepts: printable ASCII except space — the same 94 characters as
    /// the swipe grid, so both paths share an alphabet and the ASCII-only guarantee.
    static let alphabet: Set<Character> = {
        var out = Set<Character>()
        for scalar in 0x21...0x7E {
            if let unicode = Unicode.Scalar(scalar) { out.insert(Character(unicode)) }
        }
        return out
    }()

    static func filtered(_ input: String) -> String {
        String(input.filter { alphabet.contains($0) })
    }

    /// Bits per character, inferred from the distinct symbols used. See the type note for why.
    static func bitsPerCharacter(for input: String) -> Double {
        let distinct = Set(filtered(input)).count
        if distinct <= 1 { return 0 }
        if distinct > mechanicalAlphabetCeiling { return humanTypingBits }
        return log2(Double(distinct))
    }

    static func estimatedBits(for input: String) -> Double {
        let accepted = filtered(input)
        return Double(accepted.count) * bitsPerCharacter(for: accepted)
    }

    /// Characters still needed to reach `requiredBits` at the current inferred rate. Recomputed as the
    /// user types, because the rate itself moves as the alphabet reveals itself.
    static func charactersRemaining(for input: String, requiredBits: Double) -> Int {
        let rate = bitsPerCharacter(for: input)
        // Before a second distinct symbol appears there is no rate yet; quote the pessimistic one so
        // the target never jumps upward as they type.
        let effective = rate > 0 ? rate : humanTypingBits
        let needed = Int((requiredBits / effective).rounded(.up))
        return max(0, needed - filtered(input).count)
    }

    /// Why this input isn't acceptable yet, or nil when it is.
    ///
    /// The structural half matters as much as the arithmetic — it is the part that actually stops
    /// `111111…` and `123123…`, and it is alphabet-independent so one rule covers every kind of input.
    static func rejectionReason(for input: String, requiredBits: Double) -> EntropyRejection? {
        let accepted = filtered(input)
        let distinct = Set(accepted).count
        if distinct < 2 { return .tooFewDistinctCharacters(distinct, 2) }
        if let share = dominantCharacterShare(accepted), share > maxCharacterShare {
            return .repetitivePattern
        }
        if isShortPeriodRepetition(accepted) { return .repetitivePattern }
        let bits = estimatedBits(for: accepted)
        if bits < requiredBits { return .notEnoughBits(bits, requiredBits) }
        return nil
    }

    /// No single symbol may take more than this share. Honest coin flips sit near 0.5, so this catches
    /// a dominated sequence without punishing a lopsided run of luck.
    private static let maxCharacterShare = 0.7
    /// Longest cycle we test for. Someone padding the box types a short repeat, not a long one.
    private static let maxTestedPeriod = 8

    private static func dominantCharacterShare(_ input: String) -> Double? {
        let characters = Array(input)
        guard !characters.isEmpty else { return nil }
        var counts: [Character: Int] = [:]
        for character in characters { counts[character, default: 0] += 1 }
        guard let highest = counts.values.max() else { return nil }
        return Double(highest) / Double(characters.count)
    }

    private static func isShortPeriodRepetition(_ input: String) -> Bool {
        let characters = Array(input)
        guard characters.count >= 4 else { return false }
        for period in 1...min(maxTestedPeriod, characters.count / 2) {
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
