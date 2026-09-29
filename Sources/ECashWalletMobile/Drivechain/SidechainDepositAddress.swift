// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Crypto   // swift-crypto: SHA-256 on both platforms

/// A sidechain deposit address as users paste it, unwrapped to the bare address a deposit's
/// OP_RETURN must carry.
///
/// Sidechain wallets show deposit addresses as `s<slot>_<address>_<checksum>`, where the checksum is
/// `hex(sha256("s<slot>_<address>_")[0..3])` (thunder-rust `format_for_deposit`, BitWindow
/// `DecodeDepositAddress`). That wrapper is a **display form only**: written into the OP_RETURN
/// verbatim, the sidechain credits an address nobody controls. So the rule is unwrap, verify, and
/// only ever hand the engine the middle part (which the engine also checks, refusing any `_`).
enum SidechainDepositAddress {
    enum Failure: Error, Equatable {
        case empty
        /// Not `address`, `s<slot>_<address>` or `s<slot>_<address>_<checksum>`.
        case malformed
        /// The checksum doesn't match: almost certainly a typo.
        case badChecksum
        /// A valid address for a different sidechain (e.g. BitNames' `s2_…` in a Thunder deposit).
        case wrongSidechain(slot: Int)
    }

    /// The bare address to deposit to sidechain `slot`, from what the user pasted or scanned.
    /// A bare address (no `s<slot>_` prefix) is accepted as-is: the sidechain is already chosen.
    static func parse(_ input: String, slot: Int) -> Result<String, Failure> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let parts = text.split(separator: "_", omittingEmptySubsequences: false).map(String.init)

        switch parts.count {
        case 1:
            return isPlausibleAddress(text) ? .success(text) : .failure(.malformed)
        case 2, 3:
            guard let found = prefixSlot(parts[0]) else { return .failure(.malformed) }
            let address = parts[1]
            guard isPlausibleAddress(address) else { return .failure(.malformed) }
            if parts.count == 3 {
                // Check the checksum against the slot the ADDRESS names, so a typo reads as a typo
                // even when the slot is also wrong.
                guard parts[2].lowercased() == checksum(slot: found, address: address) else {
                    return .failure(.badChecksum)
                }
            }
            guard found == slot else { return .failure(.wrongSidechain(slot: found)) }
            return .success(address)
        default:
            return .failure(.malformed)
        }
    }

    /// `s<slot>_<address>_<checksum>`, for showing the user where a deposit goes in the same form
    /// their sidechain wallet shows.
    static func displayForm(address: String, slot: Int) -> String {
        "s\(slot)_\(address)_\(checksum(slot: slot, address: address))"
    }

    static func checksum(slot: Int, address: String) -> String {
        let digest = SHA256.hash(data: Data("s\(slot)_\(address)_".utf8))
        return Array(digest).prefix(3).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    /// `s9` → 9. Slots are 0–255.
    private static func prefixSlot(_ part: String) -> Int? {
        guard part.hasPrefix("s"), let n = Int(part.dropFirst()), (0...255).contains(n) else { return nil }
        return n
    }

    /// Sidechain address formats differ (Thunder is base58, others aren't), so this checks only what
    /// every one shares: printable, no spaces, no underscores, short enough for one OP_RETURN push.
    private static func isPlausibleAddress(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 75 else { return false }
        return s.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f && $0 != "_" }
    }
}
