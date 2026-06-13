// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Pure normalization for user-entered recovery phrases (the Import flow). Lives in
/// WalletService so the rules are parity-tested next to the BDK validation that consumes the
/// result. Bridged (public, String/Int/Bool only). NO validation beyond word count happens
/// here — word-list membership and the checksum are BDK's job (`Mnemonic.fromString`), and
/// rejection stays non-leaky (Golden Rule §2: never echo entered words anywhere).
public enum MnemonicInput {
    /// Lowercase, split on any run of whitespace/newlines, drop empties, join single-spaced —
    /// tolerant of pasted phrases with line breaks, tabs, or stray spacing.
    public static func normalize(_ raw: String) -> String {
        words(raw).joined(separator: " ")
    }

    public static func wordCount(_ raw: String) -> Int {
        words(raw).count
    }

    /// BIP39 phrases we accept: exactly 12 or 24 words (CLAUDE.md §7).
    public static func hasValidWordCount(_ raw: String) -> Bool {
        let count = wordCount(raw)
        return count == 12 || count == 24
    }

    private static func words(_ raw: String) -> [String] {
        // String-separator splitting only: the CharacterSet overload of
        // `components(separatedBy:)` doesn't transpile ("Unresolved reference
        // 'whitespacesAndNewlines'"); normalize separators to spaces first.
        raw.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
