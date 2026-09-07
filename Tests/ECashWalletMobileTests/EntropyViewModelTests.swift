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

    /// A clock that advances a second per read — the `now` seam is `@Sendable`, so it can't capture a
    /// mutable local.
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 1_000
        func next() -> Int64 {
            lock.withLock { defer { value += 1_000 }; return value }
        }
    }

    @Test func clearRefreezesBothComponents() {
        let clock = StepClock()
        let vm = EntropyViewModel(randomBytes: { Data([UInt8](repeating: 0x01, count: $0)) },
                                  now: { clock.next() })
        #expect(vm.timestampMillis == 1_000)
        fill(vm)
        vm.clear()
        #expect(vm.timestampMillis == 2_000)
        #expect(vm.userInput.isEmpty)
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

    @Test func typedInputIsFilteredToTheDeclaredSource() {
        let vm = viewModel()
        vm.inputMethod = .typed
        vm.typedSource = .diceD6
        vm.typedInput = "1a2b3c"
        #expect(vm.userInput == "123")
        #expect(vm.field.hasSuffix("123"))
    }

    @Test func typedRemainingCountsDownForTheDeclaredSource() {
        let vm = viewModel()
        vm.inputMethod = .typed
        vm.typedSource = .diceD6
        #expect(vm.typedCharactersRemaining == 50)      // 128 bits at log2(6)
        vm.typedInput = "351426134562"
        #expect(vm.typedCharactersRemaining == 38)
    }

    @Test func appendRejectsCharactersOutsideTheSource() {
        let vm = viewModel()
        vm.inputMethod = .typed
        vm.typedSource = .diceD6
        vm.appendTyped("4")
        vm.appendTyped("9")        // not a d6 face
        #expect(vm.typedInput == "4")
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
