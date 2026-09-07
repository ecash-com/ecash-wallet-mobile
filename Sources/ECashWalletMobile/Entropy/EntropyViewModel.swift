// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation   // @Observable — SkipFuse alone isn't enough ("unknown attribute 'Observable'")
import SkipFuse
import Crypto        // swift-crypto — SHA-256 on both platforms. NOT WalletService's CoinNewsCrypto,
                     // which is `@nobridge` and so unreachable from this (native) module.
import WalletService

/// How the entropy field is being filled (`docs/user-provided-entropy.md` §3).
enum EntropyMode: String, CaseIterable, Equatable {
    /// A CSPRNG prefix plus the user's own input. **The default**, because it is never worse than
    /// user-only and better whenever the user's randomness is worse than they think: a healthy CSPRNG
    /// carries it, and a broken one degrades it to exactly the user's contribution — which is gated at
    /// the full target anyway.
    case mixed
    /// The user's input alone, with an empty CSPRNG component. Kept for the one case that genuinely
    /// needs it: reproducing a wallet from material generated entirely off-device, with nothing from
    /// the phone in it.
    case userOnly
}

/// How the user is supplying their own entropy.
enum EntropyInputMethod: String, CaseIterable, Equatable {
    case swipe
    case typed
}

/// Drives the paranoid-mode entropy screen.
///
/// Owns the two components the user cannot type — the CSPRNG prefix and the timestamp — and **freezes
/// both when the screen opens**. That is not incidental: the audit story is "hash the string you see",
/// so every component must already be in the visible field and must not change underneath the user. A
/// timestamp read at submit time and never displayed would be unreproducible.
///
/// Freezing at open also satisfies the system-first invariant (§3): the CSPRNG prefix is fixed before
/// the user starts, so a compromised RNG cannot adapt its output to cancel what the user contributes.
@Observable
@MainActor
final class EntropyViewModel {

    // MARK: - Frozen at open

    /// SHA-256 of 32 CSPRNG bytes, hex — or empty in user-only mode. Hashing here is *formatting*, not
    /// strengthening: `SHA-256(random)` has no more entropy than `random`, it is just a tidy fixed
    /// width.
    private(set) var systemHex: String = ""
    /// Captured once, at open. Credited **zero bits** — it carries ~27 bits at best against an attacker
    /// who knows the day, and hashing it would only make a guessable value look like a 256-bit one.
    private(set) var timestampMillis: Int64 = 0

    // MARK: - User choices

    var mode: EntropyMode = .mixed {
        didSet { if mode != oldValue { refreshSystemComponent() } }
    }
    var inputMethod: EntropyInputMethod = .swipe
    /// Moved onto this screen from Settings: it sets the 128 vs 256-bit target, so it directly changes
    /// how much work the user has to do. Showing it where it has consequences beats a preference set
    /// months ago.
    var wordCount: Int = 12

    // MARK: - Input

    private(set) var accumulator = EntropyAccumulator()
    /// Raw typed input, before alphabet filtering.
    var typedInput: String = ""

    // MARK: - Seams

    private let randomBytes: @Sendable (Int) -> Data
    private let now: @Sendable () -> Int64

    init(randomBytes: @escaping @Sendable (Int) -> Data = EntropyViewModel.secureRandomBytes,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         wordCount: Int = 12) {
        self.randomBytes = randomBytes
        self.now = now
        self.wordCount = wordCount
        self.timestampMillis = now()
        refreshSystemComponent()
    }

    /// 32 bytes from the platform CSPRNG.
    ///
    /// `SystemRandomNumberGenerator` is Swift's own, and is cryptographically secure on every platform
    /// it ships for — including Android under Fuse, where it reads the OS entropy source. **This is why
    /// the draw lives app-side rather than in the transpiled WalletService**: there, `Int.random` would
    /// become Kotlin's `kotlin.random.Random`, which is *not* cryptographically secure.
    @Sendable
    nonisolated static func secureRandomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        for _ in 0..<count {
            bytes.append(UInt8.random(in: UInt8(0)...UInt8(255), using: &generator))
        }
        return Data(bytes)
    }

    // MARK: - Field

    /// True when the user pasted back a complete field rather than typing raw input.
    ///
    /// This is what makes "Copy" mean something. Copy hands over the whole field, so pasting it back
    /// must reproduce the same wallet — otherwise the reproducibility promise is only theoretical.
    /// Without this the pasted field would be treated as a contribution and nested inside a fresh one,
    /// giving different words for what looks like identical input.
    var isRestoringFromPastedField: Bool {
        inputMethod == .typed && EntropyDerivation.isField(trimmedTypedInput)
    }

    private var trimmedTypedInput: String {
        typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The complete, visible entropy field — exactly what gets hashed, and exactly what the user can
    /// copy and verify.
    var field: String {
        if isRestoringFromPastedField { return trimmedTypedInput }
        return EntropyDerivation.field(wordCount: wordCount, systemHex: systemHex,
                                       timestampMillis: timestampMillis, userInput: userInput)
    }

    /// The word count in force. A pasted field carries its own — deriving it at the Settings value
    /// instead would silently produce a different wallet from the one being restored.
    var effectiveWordCount: Int {
        if isRestoringFromPastedField,
           let fromField = EntropyDerivation.wordCount(inField: trimmedTypedInput) {
            return fromField
        }
        return wordCount
    }

    /// The user's own contribution, by input method.
    var userInput: String {
        switch inputMethod {
        case .swipe: return accumulator.userInput
        case .typed: return TypedEntropyEstimator.filtered(typedInput)
        }
    }

    /// The derived entropy in hex, for the confirm step and the audit comparison.
    var entropyHex: String? {
        EntropyDerivation.entropyHex(field: field, wordCount: effectiveWordCount)
    }

    // MARK: - Progress

    /// How much more than the nominal target a **swipe** must estimate before it is accepted.
    ///
    /// The credit rates are a model of how unpredictable human swiping is, not a measurement — and a
    /// model can be wrong in the dangerous direction: people start swipes where their thumb rests,
    /// paths have characteristic curvature, and a person's velocity is consistent enough that dwell is
    /// worth less than assumed. Requiring double means that even if the model over-credits by 2×, the
    /// wallet still carries its nominal entropy.
    ///
    /// It costs seconds. At the measured ~20 runs/second this is about 5 seconds for 12 words and 10
    /// for 24, against 2.5 and 5 without it.
    static let swipeSafetyFactor = 2.0

    /// The nominal entropy for the word count — 128 or 256 bits.
    var nominalBits: Double { effectiveWordCount == 24 ? 256 : 128 }

    /// What this input must reach.
    ///
    /// **The margin applies to swiping only.** A swipe's figure comes from a behavioural model, so it
    /// gets doubled. Typed input from a mechanical source does not: fifty d6 rolls really are 129 bits
    /// by arithmetic on `log2(6)`, not a guess about behaviour, and demanding a hundred rolls would
    /// double someone's physical dice-rolling for no gain. Typed input has its own conservatism — an
    /// alphabet over 16 symbols drops to 1 bit per character precisely because it can't be trusted as
    /// mechanical.
    var requiredBits: Double {
        switch inputMethod {
        case .swipe: return nominalBits * Self.swipeSafetyFactor
        case .typed: return nominalBits
        }
    }

    /// Bits credited to the **user's contribution only**.
    ///
    /// The CSPRNG prefix is deliberately excluded. Crediting it would let the gate turn green before
    /// the user has swiped at all, silently turning mixed mode back into system-only — the whole point
    /// of mixed is that the user's own material clears the bar on its own, so the wallet is safe even
    /// if the system's contribution is worthless.
    var estimatedBits: Double {
        switch inputMethod {
        case .swipe: return accumulator.estimatedBits()
        case .typed: return TypedEntropyEstimator.estimatedBits(for: typedInput)
        }
    }

    /// Fills only as far as the gate is actually open.
    ///
    /// It used to track bits alone, so it could sit at 100% while Continue stayed disabled — the bit
    /// target is only one of the conditions, and the structural checks (distinct characters, separate
    /// strokes, no repetition) can still be failing. A full bar that doesn't let you continue reads as
    /// a broken app. It now reaches 1.0 only when everything passes, and is held just short otherwise.
    var progress: Double {
        if canContinue { return 1.0 }
        guard requiredBits > 0 else { return 0 }
        return min(0.95, estimatedBits / requiredBits)
    }

    /// Why the input isn't acceptable yet, or nil when it is.
    var rejection: EntropyRejection? {
        switch inputMethod {
        case .swipe: return accumulator.rejectionReason(requiredBits: requiredBits)
        case .typed: return TypedEntropyEstimator.rejectionReason(for: typedInput,
                                                                    requiredBits: requiredBits)
        }
    }

    /// A restore is exempt from the entropy gate, deliberately and for the same reason importing a
    /// recovery phrase is: the user is reproducing a wallet that already exists, not creating one. Its
    /// entropy was gated when it was first made. Requiring the gate again would make it impossible to
    /// restore the very wallet this feature promises you can restore.
    var canContinue: Bool {
        if isRestoringFromPastedField { return entropyHex != nil }
        return rejection == nil
    }

    /// How many more characters are needed at the currently inferred rate. Moves as the user types,
    /// because the rate itself is inferred from the alphabet they reveal.
    var typedCharactersRemaining: Int {
        TypedEntropyEstimator.charactersRemaining(for: typedInput, requiredBits: requiredBits)
    }

    /// The inferred rate, shown so the estimate isn't a black box.
    var typedBitsPerCharacter: Double {
        TypedEntropyEstimator.bitsPerCharacter(for: typedInput)
    }

    // MARK: - Actions

    /// Milliseconds a cell must be dwelt on before it emits another copy of itself.
    ///
    /// Without this, a drag at 60–120 Hz records a repeat every 8–16 ms and the string fills with
    /// them. The dwell signal only needs to be *proportional* to time spent, not sampled at the
    /// device's full rate (§6.2).
    static let minRepeatIntervalMillis: Int64 = 35

    /// When the last sample was recorded, so repeats can be throttled.
    private var lastSampleAtMillis: Int64 = 0

    /// Record one sample from the grid.
    ///
    /// **Transitions are never throttled; repeats are.** A move to a new cell is the part that carries
    /// entropy (1.5 bits) and dropping one would lose real signal. A repeat only encodes dwell, and
    /// dwell stays proportional to time whether it is sampled every 16 ms or every 55 — sampling it
    /// coarsely just makes the recorded string a fraction of the length for the same information.
    func recordSwipe(_ character: Character, startsGesture: Bool) {
        let timestamp = now()
        let isRepeat = !startsGesture && accumulator.samples.last == character
        if isRepeat && timestamp - lastSampleAtMillis < Self.minRepeatIntervalMillis { return }
        lastSampleAtMillis = timestamp
        accumulator.record(character, startsGesture: startsGesture)
    }

    /// Start over. Re-draws the CSPRNG prefix and re-stamps the timestamp — this is a fresh session,
    /// so both frozen components are re-frozen. (Returning from background must NOT do this.)
    func clear() {
        accumulator.reset()
        typedInput = ""
        timestampMillis = now()
        refreshSystemComponent()
    }

    /// Start a session if there isn't one, freezing the CSPRNG prefix and the timestamp.
    ///
    /// **Idempotent on purpose, and both halves matter.** SwiftUI can construct a `NavigationLink`
    /// destination eagerly and fire `onDisappear` on that offscreen instance, which wiped the frozen
    /// components before the user ever saw the screen — the field then read `v1&12&&0&`. So the view
    /// calls this on appear. Equally, returning from background must NOT re-freeze anything, or the
    /// field would change under a user mid-input, so this only acts when there is no session at all.
    func beginSessionIfNeeded() {
        guard timestampMillis == 0 else { return }
        timestampMillis = now()
        refreshSystemComponent()
    }

    /// Wipe every trace of the input. Called when the screen is dismissed and once the wallet is made:
    /// the field is seed-equivalent, the mnemonic is the real backup, and there is no reason for a
    /// second copy to outlive the screen.
    func wipe() {
        accumulator.reset()
        typedInput = ""
        systemHex = ""
        timestampMillis = 0
    }

    private func refreshSystemComponent() {
        switch mode {
        case .mixed:
            systemHex = EntropyDerivation.hex(Data(SHA256.hash(data: randomBytes(32))))
        case .userOnly:
            systemHex = ""
        }
    }
}
