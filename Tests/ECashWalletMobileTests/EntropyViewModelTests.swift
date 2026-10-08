// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The create-wallet entropy screen's state machine (`docs/user-provided-entropy.md` §3).
///
/// Always mixed, always swipe, and never gated (2026-10-08): the CSPRNG prefix alone is a
/// full-strength seed, so the user can continue at any point and the bar only measures what they add.
/// `theFrozenComponentsDoNotMoveUnderTheUser` guards reproducibility of the visible field.
@MainActor
@Suite struct EntropyViewModelTests {

    /// Deterministic seams so the field is predictable.
    private func viewModel(wordCount: Int = 12, clock: Int64 = 1_750_000_000_000) -> EntropyViewModel {
        EntropyViewModel(randomBytes: { count in Data([UInt8](repeating: 0xAB, count: count)) },
                         now: { clock },
                         wordCount: wordCount)
    }

    /// Varied input across 24 strokes — enough to clear the 12-word swipe gate, which asks for 1000
    /// estimated bits (about eight times the nominal 128) because a swipe's figure is a model rather
    /// than a measurement.
    private func fill(_ vm: EntropyViewModel) {
        var index = 0
        for _ in 0..<24 {
            for scalar in 0x41...0x5A {
                vm.recordSwipe(Character(Unicode.Scalar(scalar)!), startsGesture: index % 26 == 0)
                index += 1
            }
        }
    }

    // MARK: - Frozen components

    /// Both components the user cannot type are captured at open and must not move afterwards. A
    /// timestamp read at submit time — or a prefix redrawn mid-session — would make the visible field
    /// stop matching the wallet it produced.
    @Test func theFrozenComponentsDoNotMoveUnderTheUser() {
        let vm = viewModel()
        let hex = vm.systemHex
        let stamp = vm.timestampMillis
        fill(vm)
        #expect(vm.systemHex == hex)
        #expect(vm.timestampMillis == stamp)
    }

    /// The CSPRNG prefix is generated before the user starts, so a compromised RNG cannot adapt its
    /// output to cancel what the user contributes (§3, system-first invariant).
    @Test func theCSPRNGPrefixExistsBeforeAnyInput() {
        let vm = viewModel()
        #expect(!vm.systemHex.isEmpty)
        #expect(vm.systemHex.count == 64)      // SHA-256, hex
        #expect(vm.userInput.isEmpty)
    }

    /// A clock the test moves explicitly. Not a self-advancing one: `recordSwipe` reads the clock on
    /// every sample to throttle repeats, so a stepping clock would race ahead during `fill`.
    /// The `now` seam is `@Sendable`, hence a class rather than a captured local.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ start: Int64) { value = start }
        func now() -> Int64 { lock.withLock { value } }
        func advance(to newValue: Int64) { lock.withLock { value = newValue } }
    }

    @Test func clearRefreezesBothComponents() {
        let clock = TestClock(1_000)
        let vm = EntropyViewModel(randomBytes: { Data([UInt8](repeating: 0x01, count: $0)) },
                                  now: { clock.now() })
        #expect(vm.timestampMillis == 1_000)
        fill(vm)
        clock.advance(to: 2_000)
        vm.clear()
        #expect(vm.timestampMillis == 2_000)
        #expect(vm.userInput.isEmpty)
    }

    /// Repeats are throttled so a 60–120 Hz drag doesn't fill the string with them, but a move to a
    /// **new** cell is never dropped — that transition is the part carrying entropy.
    @Test func repeatsAreThrottledButTransitionsAreNot() {
        let clock = TestClock(0)
        let vm = EntropyViewModel(randomBytes: { Data([UInt8](repeating: 0x01, count: $0)) },
                                  now: { clock.now() })
        vm.recordSwipe("A", startsGesture: true)
        vm.recordSwipe("A", startsGesture: false)     // same cell, same instant — dropped
        vm.recordSwipe("A", startsGesture: false)     // dropped
        #expect(vm.userInput == "A")

        vm.recordSwipe("B", startsGesture: false)     // a transition, never throttled
        #expect(vm.userInput == "AB")

        clock.advance(to: EntropyViewModel.minRepeatIntervalMillis)
        vm.recordSwipe("B", startsGesture: false)     // enough dwell has passed
        #expect(vm.userInput == "ABB")
    }

    /// **Regression: the field rendered as `v1&12&&0&` on the simulator.** SwiftUI builds a
    /// `NavigationLink` destination eagerly and fires `onDisappear` on that offscreen instance, wiping
    /// the frozen components; the same `@State` object is then reused when the user actually
    /// navigates. Every wallet made that way would have had NO system entropy while the UI said Mixed.
    @Test func aWipedSessionIsRestartedOnAppear() {
        let vm = viewModel()
        vm.wipe()
        #expect(vm.systemHex.isEmpty)
        #expect(vm.timestampMillis == 0)

        vm.beginSessionIfNeeded()
        #expect(vm.systemHex.count == 64)
        #expect(vm.timestampMillis != 0)
        #expect(!vm.field.hasPrefix("v1&12&&0&"))
    }

    /// The other half: returning from background must NOT re-freeze anything, or the field would
    /// change under a user who is part-way through swiping.
    @Test func beginSessionIsANoOpWhenASessionExists() {
        let vm = viewModel()
        let hex = vm.systemHex
        let stamp = vm.timestampMillis
        fill(vm)
        vm.beginSessionIfNeeded()
        vm.beginSessionIfNeeded()
        #expect(vm.systemHex == hex)
        #expect(vm.timestampMillis == stamp)
        #expect(!vm.userInput.isEmpty)      // and the input survives
    }

    // MARK: - The meter

    /// The bar measures the user's swiping only. If the CSPRNG prefix counted, it would open full
    /// before the user swiped at all and say nothing about what they added.
    @Test func theMeterIgnoresTheCSPRNGPrefix() {
        let vm = viewModel()
        #expect(!vm.systemHex.isEmpty)     // a full 256-bit prefix is present…
        #expect(vm.estimatedBits == 0)     // …and the bar is empty
        #expect(!vm.isFull)
    }

    /// Only a short swipe is required: past the minimum the entropy is usable well before the bar
    /// fills, because the device's randomness alone is a full-strength seed.
    @Test func aShortSwipeUnlocksBeforeTheBarFills() {
        let vm = viewModel()
        #expect(!vm.canContinue)                  // no swipes yet
        vm.recordSwipe("A", startsGesture: true)
        #expect(!vm.canContinue)                  // a single tap isn't enough
        var index = 0
        while !vm.hasMinimumInput {
            vm.recordSwipe(Character(Unicode.Scalar(0x41 + index % 26)!), startsGesture: index % 26 == 0)
            index += 1
        }
        #expect(vm.canContinue)
        #expect(!vm.isFull)                       // well short of a full bar
        #expect(vm.progress < 0.25)
        fill(vm)
        #expect(vm.isFull)
        #expect(vm.canContinue)
    }

    @Test func theMinimumIsTheNominalSize() {
        #expect(viewModel().minimumBits == 128)
        #expect(viewModel(wordCount: 24).minimumBits == 256)
    }

    /// A session with no system component can't continue even with plenty of swiping — its field
    /// would be nothing but the user's swipes.
    @Test func aWipedSessionCannotContinue() {
        let vm = viewModel()
        vm.wipe()
        fill(vm)
        #expect(!vm.canContinue)
        vm.beginSessionIfNeeded()
        #expect(vm.canContinue)
    }

    @Test func twentyFourWordsRaisesTheTarget() {
        let vm = viewModel(wordCount: 24)
        #expect(vm.requiredBits == EntropyViewModel.swipeRequiredBits24)
        fill(vm)
        #expect(!vm.isFull)                // enough for 12 words, not for 24
    }

    /// The bar asks for far more than the nominal entropy, because a swipe's figure comes from a
    /// behavioural model rather than a measurement.
    @Test func theSwipeTargetIsALargeMultiple() {
        let vm = viewModel()
        #expect(vm.requiredBits == EntropyViewModel.swipeRequiredBits12)
        #expect(vm.requiredBits > vm.nominalBits * 5)
    }

    /// A full bar must mean "ready" — it used to track bits alone and could sit at 100% while the
    /// structural checks still blocked Continue.
    @Test func theBarOnlyFillsWhenTheGateIsOpen() {
        let vm = viewModel()
        // Two characters, repeated: racks up bits but fails the distinct-character check.
        for index in 0..<900 {
            vm.recordSwipe(index % 2 == 0 ? "A" : "B", startsGesture: index == 0)
        }
        #expect(vm.estimatedBits >= vm.requiredBits)   // bits satisfied…
        #expect(!vm.isFull)                            // …checks still failing
        #expect(vm.progress < 1.0)                     // …so the bar must not read full
    }

    // MARK: - Field and derivation

    /// The input box shows the whole hashed string: prefilled with version, word count, device
    /// randomness and timestamp, with swipes appended.
    @Test func theInputIsPrefilledWithTheWholeField() {
        let vm = viewModel()
        #expect(vm.displayedInput == "v1&12&\(vm.systemHex)&1750000000000&")
        vm.recordSwipe("A", startsGesture: true)
        #expect(vm.displayedInput == "v1&12&\(vm.systemHex)&1750000000000&A")
        #expect(vm.displayedInput == vm.field)
    }

    @Test func theFieldCarriesTheUsersInput() {
        let vm = viewModel()
        fill(vm)
        #expect(vm.field.hasPrefix("v1&12&"))
        #expect(vm.field.hasSuffix(vm.userInput))
        #expect(vm.entropyHex?.count == 32)      // 16 bytes
    }

    /// Changing the word count changes the field prefix, so the derivation is domain-separated — the
    /// same swipe cannot yield related 12- and 24-word wallets.
    @Test func theWordCountChangesTheDerivation() {
        let vm = viewModel()
        fill(vm)
        let twelve = vm.entropyHex
        vm.wordCount = 24
        let twentyFour = vm.entropyHex
        #expect(twelve != nil)
        #expect(twentyFour?.count == 64)
        #expect(twentyFour?.hasPrefix(twelve!) == false)
    }

    // MARK: - Editing

    /// Pasting a saved field reproduces its wallet: the edited string is used exactly as written,
    /// whatever this session's own randomness was.
    @Test func pastingASavedFieldReproducesTheSameEntropy() {
        let original = viewModel()
        fill(original)
        let saved = original.field
        let expected = original.entropyHex

        let restored = viewModel(clock: 999)
        restored.applyEdit("  \(saved)\n")             // surrounding whitespace from a paste is dropped
        #expect(restored.isEdited)
        #expect(restored.field == saved)
        #expect(restored.displayedInput == saved)
        #expect(restored.entropyHex == expected)
    }

    /// The editor is for testing and restoring, so the swipe minimum doesn't apply.
    @Test func anEditedFieldSkipsTheSwipeMinimum() {
        let vm = viewModel()
        vm.applyEdit("v1&12&&0&abc")
        #expect(!vm.hasMinimumInput)
        #expect(vm.canContinue)
    }

    /// …but it must still be a field: anything not starting `v1&12&` / `v1&24&` can't be derived.
    @Test func anEditedStringMustBeAField() {
        let vm = viewModel()
        vm.applyEdit("just some text")
        #expect(vm.isEdited)
        #expect(vm.entropyHex == nil)
        #expect(!vm.canContinue)
    }

    /// A pasted field carries its own word count — deriving at the Settings value would refuse it.
    @Test func anEditedFieldKeepsItsOwnWordCount() {
        let saved = viewModel(wordCount: 24).field + "abc"
        let vm = viewModel(wordCount: 12)
        vm.applyEdit(saved)
        #expect(vm.effectiveWordCount == 24)
        #expect(vm.entropyHex?.count == 64)
    }

    /// Swipes after an edit append to the edited string.
    @Test func swipesAfterAnEditAppendToIt() {
        let vm = viewModel()
        vm.applyEdit("v1&12&&0&abc")
        vm.recordSwipe("Z", startsGesture: true)
        #expect(vm.field == "v1&12&&0&abcZ")
    }

    /// Saving the editor unchanged keeps the generated session (and its swipe minimum).
    @Test func anUnchangedEditIsANoOp() {
        let vm = viewModel()
        vm.recordSwipe("A", startsGesture: true)
        vm.applyEdit(vm.field)
        #expect(!vm.isEdited)
        #expect(vm.userInput == "A")
    }

    /// Start over drops the edit and returns to a fresh generated session.
    @Test func startOverDropsTheEdit() {
        let vm = viewModel()
        vm.applyEdit("v1&12&&0&abc")
        vm.clear()
        #expect(!vm.isEdited)
        #expect(vm.field.hasPrefix("v1&12&\(vm.systemHex)&"))
    }

    // MARK: - Sessions

    /// Each Continue on New wallet starts a new session, and each session draws its own device
    /// randomness — backing out and continuing again must not reuse the previous draw.
    @Test func eachSessionDrawsFreshRandomness() {
        let first = EntropySession(wordCount: 12)
        let second = EntropySession(wordCount: 12)
        #expect(first != second)
        #expect(first.model.systemHex.count == 64)
        #expect(first.model.systemHex != second.model.systemHex)
        #expect(first.model.field != second.model.field)
    }

    // MARK: - Wipe

    /// The field is seed-equivalent and the mnemonic is the real backup, so nothing survives the
    /// screen (§8).
    @Test func wipeLeavesNothingBehind() {
        let vm = viewModel()
        fill(vm)
        vm.wipe()
        #expect(vm.userInput.isEmpty)
        #expect(vm.systemHex.isEmpty)
        #expect(vm.timestampMillis == 0)
        #expect(vm.estimatedBits == 0)
    }
}
