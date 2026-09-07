// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The paranoid-mode screen's state machine (`docs/user-provided-entropy.md` §3).
///
/// Two tests here guard properties that would fail silently and invisibly if they broke:
/// `theMeterIgnoresTheCSPRNGPrefix` (or mixed mode quietly becomes system-only) and
/// `theFrozenComponentsDoNotMoveUnderTheUser` (or the field stops being reproducible, which is the
/// whole promise).
@MainActor
@Suite struct EntropyViewModelTests {

    /// Deterministic seams so the field is predictable.
    private func viewModel(wordCount: Int = 12, clock: Int64 = 1_750_000_000_000) -> EntropyViewModel {
        EntropyViewModel(randomBytes: { count in Data([UInt8](repeating: 0xAB, count: count)) },
                         now: { clock },
                         wordCount: wordCount)
    }

    /// Varied input across four strokes — enough to clear the 12-word gate.
    private func fill(_ vm: EntropyViewModel) {
        var index = 0
        for _ in 0..<4 {
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

    // MARK: - Modes

    @Test func userOnlyModeEmptiesTheSystemComponent() {
        let vm = viewModel()
        #expect(!vm.systemHex.isEmpty)
        vm.mode = .userOnly
        #expect(vm.systemHex.isEmpty)
        #expect(vm.field.hasPrefix("v1&12&&"))
    }

    @Test func switchingBackToMixedRedrawsThePrefix() {
        let vm = viewModel()
        vm.mode = .userOnly
        vm.mode = .mixed
        #expect(vm.systemHex.count == 64)
    }

    // MARK: - The meter

    /// **Mixed mode's whole point.** If the CSPRNG prefix counted toward the gate, Continue would go
    /// green before the user swiped at all — silently turning mixed mode back into system-only, and
    /// removing the property that makes it safe against a broken RNG.
    @Test func theMeterIgnoresTheCSPRNGPrefix() {
        let vm = viewModel()
        #expect(!vm.systemHex.isEmpty)     // a full 256-bit prefix is present…
        #expect(vm.estimatedBits == 0)     // …and contributes nothing to the gate
        #expect(!vm.canContinue)
    }

    @Test func theGateOpensOnlyOnceTheUserHasSuppliedEnough() {
        let vm = viewModel()
        #expect(!vm.canContinue)
        fill(vm)
        #expect(vm.canContinue)
    }

    @Test func twentyFourWordsRaisesTheTarget() {
        let vm = viewModel(wordCount: 24)
        #expect(vm.requiredBits == 256)
        fill(vm)
        #expect(!vm.canContinue)           // enough for 12 words, not for 24
    }

    // MARK: - Field and derivation

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

    // MARK: - Typed input

    @Test func typedInputIsFilteredToTheAlphabet() {
        let vm = viewModel()
        vm.inputMethod = .typed
        vm.typedInput = "12 3\u{00e9}4"      // space and é are outside printable ASCII
        #expect(vm.userInput == "1234")
        #expect(vm.field.hasSuffix("1234"))
    }

    /// The rate is inferred from the alphabet the user reveals, so the "how many more" figure moves as
    /// they type — there is no declared source to read it from.
    @Test func theRemainingCountFollowsTheInferredRate() {
        let vm = viewModel()
        vm.inputMethod = .typed
        // Six distinct symbols reads as a d6: log2(6) ≈ 2.58 bits each, so ~50 for 128 bits.
        vm.typedInput = "351426"
        #expect(abs(vm.typedBitsPerCharacter - 2.585) < 0.01)
        #expect(vm.typedCharactersRemaining == 44)
    }

    /// A large alphabet is what human "random" typing looks like, and we can't tell it from a good
    /// paste — so it drops to 1 bit per character and needs far more of them.
    @Test func aLargeAlphabetIsCreditedAsHumanTyping() {
        let vm = viewModel()
        vm.inputMethod = .typed
        var input = ""
        for scalar in 0x41...0x5A { input += String(Character(Unicode.Scalar(scalar)!)) }  // 26 distinct
        vm.typedInput = input
        #expect(vm.typedBitsPerCharacter == TypedEntropyEstimator.humanTypingBits)
        #expect(vm.estimatedBits == 26)
    }

    // MARK: - Restore from a pasted field

    /// **The bug user-testing found.** Copy hands over the whole field, so pasting it back must
    /// reproduce the same wallet. Before this, the pasted field was treated as a *contribution* and
    /// nested inside a fresh one — same visible input, different words, no indication why.
    @Test func pastingACopiedFieldReproducesTheSameEntropy() {
        let original = viewModel()
        fill(original)
        let copied = original.field
        let expected = original.entropyHex

        let restored = viewModel(clock: 999)          // different clock, different CSPRNG draw
        restored.inputMethod = .typed
        restored.typedInput = copied

        #expect(restored.isRestoringFromPastedField)
        #expect(restored.field == copied)             // used verbatim, not nested
        #expect(restored.entropyHex == expected)
    }

    /// A pasted field carries its own word count — deriving at the Settings value would silently
    /// produce a different wallet from the one being restored.
    @Test func aPastedFieldKeepsItsOwnWordCount() {
        let original = viewModel(wordCount: 24)
        let copied = original.field + "somecharacters"

        let restored = viewModel(wordCount: 12)
        restored.inputMethod = .typed
        restored.typedInput = copied
        #expect(restored.effectiveWordCount == 24)
        #expect(restored.entropyHex?.count == 64)     // 32 bytes, not 16
    }

    /// A restore is exempt from the entropy gate for the same reason importing a recovery phrase is:
    /// the wallet already exists and was gated when it was made. Requiring the gate again would make
    /// it impossible to restore the very wallet this feature promises you can restore.
    @Test func aRestoreSkipsTheEntropyGate() {
        let restored = viewModel()
        restored.inputMethod = .typed
        restored.typedInput = "v1&12&&0&abc"          // far below the bit target
        #expect(restored.isRestoringFromPastedField)
        #expect(restored.canContinue)
    }

    /// Ordinary typed input is still gated — only something that parses as a field is a restore.
    @Test func ordinaryTypedInputIsStillGated() {
        let vm = viewModel()
        vm.inputMethod = .typed
        vm.typedInput = "351426"
        #expect(!vm.isRestoringFromPastedField)
        #expect(!vm.canContinue)
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
