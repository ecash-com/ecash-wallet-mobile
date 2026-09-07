// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Counts how much entropy the user has actually supplied, and refuses to be flattered.
///
/// **This type is the security mechanism of paranoid mode**, not `EntropyDerivation`. The mnemonic is a
/// pure function of the visible field, so hashing spreads what is there and creates nothing; whether
/// the resulting wallet is safe depends entirely on the field being unpredictable. Everything here
/// exists to avoid over-crediting it. See `docs/user-provided-entropy.md` §2 and §6.
///
/// **The trap it defends against.** The obvious implementation — one character per grid cell crossed,
/// credited at `log2(alphabet)` — is badly wrong in a way that looks fine. A swipe is a smooth path, so
/// the next cell is almost always one of ~3 neighbours in the direction of travel: **~1.5 bits, not
/// 6.55.** Naive accounting would show "128 bits ✓" while delivering perhaps 40, the string would look
/// like gibberish, the meter would turn green, and the wallet would be grindable.
///
/// **Why it samples fast and credits slowly.** Samples arrive at the native touch rate and repeats are
/// recorded (`AAABBBBCC`), because run lengths encode finger velocity — real motor and digitizer noise
/// that one-character-per-crossing throws away. But consecutive samples on one key are ~95%
/// predictable, so crediting per sample would be the same trap an order of magnitude worse. The string
/// is therefore decomposed into **runs**, and only runs are credited.
struct EntropyAccumulator {

    // MARK: - Credit rates (docs §6.1)

    /// A transition to a new cell mid-drag. Adjacency-limited, so the 94-character alphabet buys
    /// nothing here — a swipe still only reaches neighbours.
    static let bitsPerMidDragTransition = 1.5
    /// A transition that begins a fresh stroke. The touch-down point is uncorrelated with the previous
    /// path and is a genuine choice among all 94 cells (nominal 6.55, discounted).
    static let bitsPerTouchDownTransition = 5.0
    /// A run's length. Dwell is real but weakly distributed — measured mean run was 1.56 samples at
    /// 31 Hz, worth ~1–1.5 bits, so 1.0 is conservative and stays so at higher frame rates.
    static let bitsPerRunLength = 1.0
    /// Samples past this point in a single run earn nothing and are not recorded. A finger parked on
    /// one key is not producing entropy, and must not produce a 3,000-character string either.
    ///
    /// Paired with the view model's repeat throttle: at one repeat per 35 ms this is about a third of
    /// a second of dwell on a single key, well past the point where the run length says anything new.
    static let maxRunSamples = 10

    // MARK: - Structural floor (docs §6.3)

    static let minDistinctCharacters = 16
    static let minGestures = 3
    /// No single transition bigram may cover more than this share of the runs — catches `AB AB AB…`.
    static let maxBigramShare = 0.15

    // MARK: - State

    /// The recorded sample stream, including repeats. This is what goes into the field verbatim.
    private(set) var samples: [Character] = []
    /// Sample index at which each gesture started, so run credit knows which transitions were fresh.
    private(set) var gestureStartIndices: [Int] = []

    init() {}

    // MARK: - Input

    /// Record one sample. `startsGesture` is true for the first sample after a touch-down.
    ///
    /// Callers must apply the movement and rate gates (§6.2) before calling: a sample is only offered
    /// once the finger has travelled at least a cell width since the last one. Those are geometric
    /// concerns that belong to the view, not here.
    mutating func record(_ character: Character, startsGesture: Bool) {
        if startsGesture {
            gestureStartIndices.append(samples.count)
        } else if currentRunLength() >= Self.maxRunSamples, samples.last == character {
            return   // run cap reached — record nothing further for this dwell
        }
        samples.append(character)
    }

    mutating func reset() {
        samples = []
        gestureStartIndices = []
    }

    /// The characters as a string, for appending to the entropy field.
    var userInput: String { String(samples) }

    // MARK: - Accounting

    /// Runs, as (character, length, startedAGesture).
    func runs() -> [(character: Character, length: Int, startsGesture: Bool)] {
        var out: [(character: Character, length: Int, startsGesture: Bool)] = []
        let starts = Set(gestureStartIndices)
        var index = 0
        while index < samples.count {
            let character = samples[index]
            let startsHere = starts.contains(index)
            var length = 0
            while index + length < samples.count && samples[index + length] == character {
                length += 1
            }
            out.append((character: character, length: length, startsGesture: startsHere))
            index += length
        }
        return out
    }

    /// Estimated bits supplied so far.
    ///
    /// **An estimate, deliberately conservative — never a guarantee.** No meter can measure the
    /// entropy of human input; this one is tuned to under-report. The UI must present it as a gate,
    /// not as proof, and carry the warning that goes with paranoid mode.
    func estimatedBits() -> Double {
        var total = 0.0
        for run in runs() {
            total += run.startsGesture ? Self.bitsPerTouchDownTransition : Self.bitsPerMidDragTransition
            // Length is credited once per run, not per sample.
            if run.length > 1 { total += Self.bitsPerRunLength }
        }
        return total
    }

    // MARK: - Gating

    /// Why the input is not yet acceptable, or nil when it is.
    ///
    /// The bit target alone is **not** sufficient. Measured swiping supplies ~20 runs/second, so 128
    /// bits arrives in around three seconds — easily reached by someone lazily sweeping back and forth,
    /// which produces a plausible-looking string from a tiny subset of the grid. These structural
    /// checks, not the counter, are what actually stop that.
    func rejectionReason(requiredBits: Double) -> EntropyRejection? {
        let runList = runs()
        if Set(samples).count < Self.minDistinctCharacters {
            return .tooFewDistinctCharacters(Set(samples).count, Self.minDistinctCharacters)
        }
        if gestureStartIndices.count < Self.minGestures {
            return .tooFewGestures(gestureStartIndices.count, Self.minGestures)
        }
        if let share = dominantBigramShare(runList), share > Self.maxBigramShare {
            return .repetitivePattern
        }
        if estimatedBits() < requiredBits {
            return .notEnoughBits(estimatedBits(), requiredBits)
        }
        return nil
    }

    func isAcceptable(requiredBits: Double) -> Bool {
        rejectionReason(requiredBits: requiredBits) == nil
    }

    /// Share of run-to-run transitions taken by the most common bigram.
    ///
    /// Measured over the **run sequence**, not the raw string — over raw samples the repeats would
    /// swamp it and every input would look repetitive.
    private func dominantBigramShare(_ runList: [(character: Character, length: Int, startsGesture: Bool)]) -> Double? {
        guard runList.count >= 2 else { return nil }
        var counts: [String: Int] = [:]
        for i in 0..<(runList.count - 1) {
            let key = String(runList[i].character) + String(runList[i + 1].character)
            counts[key, default: 0] += 1
        }
        guard let highest = counts.values.max() else { return nil }
        return Double(highest) / Double(runList.count - 1)
    }

    /// Samples in the run currently being extended.
    private func currentRunLength() -> Int {
        guard let last = samples.last else { return 0 }
        var length = 0
        var index = samples.count - 1
        while index >= 0 && samples[index] == last {
            length += 1
            index -= 1
        }
        return length
    }
}

/// Why an entropy input isn't acceptable yet. Carries numbers so the UI can say what is missing rather
/// than just refusing — a user told "keep going" with no target will assume the feature is broken.
enum EntropyRejection: Equatable {
    case notEnoughBits(Double, Double)
    case tooFewDistinctCharacters(Int, Int)
    case tooFewGestures(Int, Int)
    case repetitivePattern
}
