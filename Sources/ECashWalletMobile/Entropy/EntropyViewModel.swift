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
    var typedSource: TypedEntropySource = .diceD6
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

    /// The complete, visible entropy field — exactly what gets hashed, and exactly what the user can
    /// copy and verify.
    var field: String {
        EntropyDerivation.field(wordCount: wordCount, systemHex: systemHex,
                                timestampMillis: timestampMillis, userInput: userInput)
    }

    /// The user's own contribution, by input method.
    var userInput: String {
        switch inputMethod {
        case .swipe: return accumulator.userInput
        case .typed: return typedSource.filtered(typedInput)
        }
    }

    /// The derived entropy in hex, for the confirm step and the audit comparison.
    var entropyHex: String? {
        EntropyDerivation.entropyHex(field: field, wordCount: wordCount)
    }

    // MARK: - Progress

    var requiredBits: Double { wordCount == 24 ? 256 : 128 }

    /// Bits credited to the **user's contribution only**.
    ///
    /// The CSPRNG prefix is deliberately excluded. Crediting it would let the gate turn green before
    /// the user has swiped at all, silently turning mixed mode back into system-only — the whole point
    /// of mixed is that the user's own material clears the bar on its own, so the wallet is safe even
    /// if the system's contribution is worthless.
    var estimatedBits: Double {
        switch inputMethod {
        case .swipe: return accumulator.estimatedBits()
        case .typed: return typedSource.estimatedBits(for: typedInput)
        }
    }

    var progress: Double {
        guard requiredBits > 0 else { return 0 }
        return min(1.0, estimatedBits / requiredBits)
    }

    /// Why the input isn't acceptable yet, or nil when it is.
    var rejection: EntropyRejection? {
        switch inputMethod {
        case .swipe: return accumulator.rejectionReason(requiredBits: requiredBits)
        case .typed: return typedSource.rejectionReason(for: typedInput, requiredBits: requiredBits)
        }
    }

    var canContinue: Bool { rejection == nil }

    /// How many more characters the typed source needs — the number a dice user actually wants.
    var typedCharactersRemaining: Int {
        let needed = typedSource.requiredCharacters(forBits: requiredBits)
        return max(0, needed - typedSource.filtered(typedInput).count)
    }

    // MARK: - Actions

    func recordSwipe(_ character: Character, startsGesture: Bool) {
        accumulator.record(character, startsGesture: startsGesture)
    }

    func appendTyped(_ character: Character) {
        guard typedSource.accepts(character) else { return }
        typedInput.append(character)
    }

    func backspaceTyped() {
        if !typedInput.isEmpty { typedInput.removeLast() }
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
