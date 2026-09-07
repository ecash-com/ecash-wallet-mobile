// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Turns the user-visible entropy field into BIP39 entropy bytes.
///
/// This is the whole of "paranoid mode"'s cryptography, and it is deliberately tiny — see
/// `docs/user-provided-entropy.md`. It lives in WalletService rather than the app so the derived bytes
/// are produced next to BDK and **never cross the JNI bridge**: the bridged surface carries only the
/// field string and a word count (Golden Rule §2).
///
/// ```
/// field   : v1&<wordCount>&<64 hex = SHA-256 of 32 CSPRNG bytes>&<unix millis>&<user's characters>
/// digest  : SHA-256(UTF-8(field))
/// entropy : 12 words → digest[0..<16]   ·   24 words → digest[0..<32]
/// mnemonic: BDK Mnemonic.fromEntropy(entropy)
/// ```
///
/// **Three properties this shape buys, all of them load-bearing:**
///
/// 1. **Auditable.** The field is exactly what the screen shows, so a user verifies us with
///    `printf '%s' "$(cat entropy.txt)" | shasum -a 256` and compares the leading hex. Nothing is
///    mixed in off-screen, which is what makes *mixed* mode as checkable as user-only.
/// 2. **Domain-separated for free.** Because the field begins `v1&<wordCount>&`, the 12- and 24-word
///    inputs differ, so their digests are unrelated. Without that, 12-word entropy would be a *prefix*
///    of 24-word entropy from the same input, quietly reducing a 256-bit wallet to 128 bits if a user
///    reused a string. No magic label for the user to reproduce — the separation is visible in the
///    string itself.
/// 3. **Reproducible across platforms.** The alphabet is ASCII-only, so there is no Unicode
///    normalisation (NFC vs NFD) that could make the same visible string derive different wallets on
///    iOS and Android.
///
/// **What it does NOT do: create entropy.** Hashing only spreads what the field already contains. The
/// security of a paranoid-mode wallet rests entirely on the field being unpredictable, which is why
/// the accounting in the app layer — not this file — is the actual safety mechanism.
public enum EntropyDerivation {

    /// Format version, first component of every field. Bump only alongside a deliberate scheme change;
    /// it exists so a future change is unambiguous rather than silent.
    public static let version = "v1"

    /// Component separator. Note this character is **also in the input alphabet**, so a field cannot be
    /// unambiguously parsed back into its components — which is fine, because nothing ever parses it.
    /// We only ever hash the whole string, and only ever check its leading prefix. **Do not build a
    /// parser on this format**; length-prefix the components instead if they ever need reading back.
    public static let separator = "&"

    // MARK: - Field assembly

    /// The prefix every field starts with, for a given word count. Also the validation anchor.
    public static func fieldPrefix(wordCount: Int, systemHex: String, timestampMillis: Int64) -> String {
        return version + separator + "\(wordCount)" + separator
            + systemHex + separator + "\(timestampMillis)" + separator
    }

    /// The complete field.
    ///
    /// `systemHex` is the SHA-256 of 32 CSPRNG bytes, or empty in user-only mode. `timestampMillis` is
    /// captured **once when the entropy screen opens** and frozen — read at hash time and undisplayed,
    /// it would be unreproducible, which is the one way this component could break the audit.
    ///
    /// The timestamp is stored **raw, not hashed**: it carries ~27 bits at best (an attacker who knows
    /// the day is guessing among ~86M milliseconds), and hashing it would make a guessable value *look*
    /// like a 256-bit one. Shown raw, nobody mistakes it for a source. It is credited zero bits.
    public static func field(wordCount: Int, systemHex: String,
                             timestampMillis: Int64, userInput: String) -> String {
        return fieldPrefix(wordCount: wordCount, systemHex: systemHex,
                           timestampMillis: timestampMillis) + userInput
    }

    // MARK: - Derivation

    /// Entropy byte count for a word count: 16 bytes (128 bits) for 12 words, 32 (256) for 24.
    /// nil for anything else — BIP39's other lengths are not offered by this app.
    public static func entropyByteCount(wordCount: Int) -> Int? {
        if wordCount == 12 { return 16 }
        if wordCount == 24 { return 32 }
        return nil
    }

    /// The entropy bytes for a field, or nil if the field is malformed for this word count.
    ///
    /// Internal on purpose: raw entropy is seed-equivalent and has no business on the bridged surface.
    /// The app sees only `entropyHex` (for the audit display) and the resulting wallet.
    static func entropy(field: String, wordCount: Int) -> Data? {
        guard let byteCount = entropyByteCount(wordCount: wordCount) else { return nil }
        // The field must carry the word count it is being derived for, or the domain separation that
        // property 2 above depends on would be silently absent.
        guard field.hasPrefix(version + separator + "\(wordCount)" + separator) else { return nil }

        let digest = CoinNewsCrypto.sha256(Data(Array(field.utf8)))
        guard digest.count >= byteCount else { return nil }
        // Explicit loop, not `Array(digest.prefix(n))` — an Array-from-slice does not infer in Kotlin
        // (same reason `CoinNewsCrypto.itemId` builds its 12 bytes by hand).
        var out = [UInt8]()
        for i in 0..<byteCount { out.append(digest[i]) }
        return Data(out)
    }

    /// The entropy as lowercase hex — what the confirm step shows so the user can compare it against
    /// their own `shasum` without transcribing hundreds of field characters.
    ///
    /// Bridge-safe (`String` in, `String?` out); this is the only derivation output the app ever sees.
    public static func entropyHex(field: String, wordCount: Int) -> String? {
        guard let bytes = entropy(field: field, wordCount: wordCount) else { return nil }
        return hex(bytes)
    }

    /// Lowercase hex of `data`.
    ///
    /// Written with an index loop and `String` concatenation rather than `String(format:)` or
    /// `String.append(Character)` — neither transpiles reliably.
    public static func hex(_ data: Data) -> String {
        let digits = ["0", "1", "2", "3", "4", "5", "6", "7",
                      "8", "9", "a", "b", "c", "d", "e", "f"]
        var out = ""
        for i in 0..<data.count {
            let value = Int(data[i])
            out += digits[value >> 4]
            out += digits[value & 0x0F]
        }
        return out
    }
}

#endif // !SKIP_BRIDGE
