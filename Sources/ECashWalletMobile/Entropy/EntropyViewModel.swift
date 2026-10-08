// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation   // @Observable — SkipFuse alone isn't enough ("unknown attribute 'Observable'")
import SkipFuse
import Crypto        // swift-crypto — SHA-256 on both platforms. NOT WalletService's CoinNewsCrypto,
                     // which is `@nobridge` and so unreachable from this (native) module.
import WalletService

/// Drives the create-wallet entropy screen.
///
/// **Always mixed, always swipe** (2026-10-08). The device's CSPRNG prefix is in every field and the
/// user adds to it by swiping. The earlier options screen (mixed vs "only mine", swipe vs typed) is
/// gone. Editing the string by hand (`applyEdit`) is the way to paste a saved field back in, to test
/// or to reproduce a wallet.
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

    /// SHA-256 of 32 CSPRNG bytes, hex. Empty only between `wipe()` and the next session. Hashing here is *formatting*, not
    /// strengthening: `SHA-256(random)` has no more entropy than `random`, it is just a tidy fixed
    /// width.
    private(set) var systemHex: String = ""
    /// Captured once, at open. Credited **zero bits** — it carries ~27 bits at best against an attacker
    /// who knows the day, and hashing it would only make a guessable value look like a 256-bit one.
    private(set) var timestampMillis: Int64 = 0

    // MARK: - User choices

    /// From Settings → New wallets. Sets the 128 vs 256-bit size and the swipe target.
    var wordCount: Int = 12

    // MARK: - Input

    private(set) var accumulator = EntropyAccumulator()
    /// The string the user wrote in the editor, used in place of the generated prefix. Swipes made
    /// after the edit are appended to it. nil until they edit.
    private(set) var editedBase: String?

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

    /// The complete, visible entropy field — exactly what gets hashed, and exactly what the user can
    /// copy and verify.
    var field: String {
        if let editedBase { return editedBase + userInput }
        return EntropyDerivation.field(wordCount: wordCount, systemHex: systemHex,
                                       timestampMillis: timestampMillis, userInput: userInput)
    }

    /// Whether the user has replaced the generated string by hand.
    var isEdited: Bool { editedBase != nil }

    /// The word count in force. An edited field carries its own — deriving a pasted 24-word field at
    /// the 12-word setting would refuse it, or worse, a different wallet from the one being restored.
    var effectiveWordCount: Int {
        if isEdited, let fromField = EntropyDerivation.wordCount(inField: field) { return fromField }
        return wordCount
    }

    /// The user's own contribution: what the grid has recorded.
    var userInput: String { accumulator.userInput }

    /// What the input box shows: the whole field, exactly what gets hashed — prefilled with the version,
    /// word count, device randomness and timestamp, with the user's swipes appended at the end.
    var displayedInput: String { field }

    /// The derived entropy in hex, for the confirm step and the audit comparison.
    var entropyHex: String? {
        EntropyDerivation.entropyHex(field: field, wordCount: effectiveWordCount)
    }

    // MARK: - Progress

    /// What swiping should reach for the bar to fill — roughly eight times the nominal entropy of the
    /// seed.
    ///
    /// **Guidance, not a gate** (2026-10-08). The device's 128/256 CSPRNG bits are in every field, so a
    /// wallet made before the bar fills is as strong as a normal one. Only `minimumBits` of swiping is
    /// required. The bar measures only what the user adds on top.
    ///
    /// The credit rates are a model of how unpredictable human swiping is, not a measurement, and a
    /// model can be wrong in the dangerous direction: people start swipes where their thumb rests,
    /// paths have characteristic curvature, and a person's velocity is consistent enough that dwell is
    /// worth less than assumed. The large multiple keeps a full bar meaningful even if the rates
    /// over-count. At the measured ~20 runs/second it is roughly 20 seconds for 12 words, 40 for 24.
    static let swipeRequiredBits12 = 1000.0
    static let swipeRequiredBits24 = 2000.0

    /// The nominal entropy for the word count — 128 or 256 bits.
    var nominalBits: Double { effectiveWordCount == 24 ? 256 : 128 }

    /// What the swiping must reach for the bar to read full.
    var requiredBits: Double {
        effectiveWordCount == 24 ? Self.swipeRequiredBits24 : Self.swipeRequiredBits12
    }

    /// Bits credited to the **user's contribution only**.
    ///
    /// The CSPRNG prefix is deliberately excluded, so the bar shows what the user added rather than
    /// starting full.
    var estimatedBits: Double { accumulator.estimatedBits() }

    /// Fills only once every check passes — it used to track bits alone, and sat at 100% while the
    /// structural checks (distinct characters, separate strokes, no repetition) still read as failing.
    var progress: Double {
        if isFull { return 1.0 }
        guard requiredBits > 0 else { return 0 }
        return min(0.95, estimatedBits / requiredBits)
    }

    /// Why the swiping hasn't reached a full bar yet, or nil when it has.
    var rejection: EntropyRejection? {
        accumulator.rejectionReason(requiredBits: requiredBits)
    }

    /// The swiping has cleared the bit target and every structural check: the bar reads full (green).
    var isFull: Bool { rejection == nil }

    /// The least swiping that unlocks "Use this entropy": the seed's nominal size by the swipe model
    /// (128 estimated bits for 12 words, 256 for 24) — a few seconds, about an eighth of the bar.
    ///
    /// The CSPRNG prefix already makes the field a full-strength seed, so this isn't what the wallet's
    /// security rests on. It makes sure the user actually adds something of their own before going on,
    /// rather than tapping straight through.
    var minimumBits: Double { nominalBits }

    /// Whether the user has swiped enough to go on. Short of a full bar is fine (2026-10-08).
    var hasMinimumInput: Bool { estimatedBits >= minimumBits }

    /// Needs a live session (an empty system component — a wiped session that hasn't restarted —
    /// would leave a field of nothing but swipes) and the minimum swiping.
    ///
    /// **An edited field skips both**, deliberately, as importing a recovery phrase does: editing is
    /// how a saved field is pasted back to reproduce its wallet, which must work as written. It only
    /// has to be a well-formed field.
    var canContinue: Bool {
        if isEdited { return entropyHex != nil }
        return !systemHex.isEmpty && entropyHex != nil && hasMinimumInput
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

    /// Replace the whole string with what the user wrote in the editor. Swipes so far are folded into
    /// it (they were part of the text being edited), so later swipes append to the edited string.
    func applyEdit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == field { return }      // unchanged: stay on the generated session
        accumulator.reset()
        editedBase = trimmed
    }

    /// Start over. Re-draws the CSPRNG prefix and re-stamps the timestamp — this is a fresh session,
    /// so both frozen components are re-frozen. (Returning from background must NOT do this.)
    func clear() {
        accumulator.reset()
        editedBase = nil
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
        editedBase = nil
        systemHex = ""
        timestampMillis = 0
    }

    private func refreshSystemComponent() {
        systemHex = EntropyDerivation.hex(Data(SHA256.hash(data: randomBytes(32))))
    }
}
