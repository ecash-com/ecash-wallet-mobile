// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Crypto   // Apple's swift-crypto — CryptoKit API on Apple, BoringSSL-backed off-Apple

/// SPIKE (docs/thunder-sidechain-support.md §5a): prove Apple's `swift-crypto` **ed25519**
/// (`Curve25519.Signing`) compiles + runs on BOTH iOS and Android (Skip Fuse, Swift Android SDK).
/// This is the gating question for the Thunder sidechain crypto stack — Thunder signs with ed25519.
/// Not wired into any UI; existence + reference is enough to exercise the cross-platform build.
enum ThunderCryptoSpike {
    /// Generate an ed25519 key, sign a message, and verify — a full round-trip. `true` on success.
    static func ed25519RoundTrip() -> Bool {
        let key = Curve25519.Signing.PrivateKey()
        let message = Data("thunder".utf8)
        guard let signature = try? key.signature(for: message) else { return false }
        return key.publicKey.isValidSignature(signature, for: message)
    }

    /// The 32-byte ed25519 public key — what a Thunder address hashes via `BLAKE3(pubkey)[..20]`.
    static func newPublicKeyBytes() -> [UInt8] {
        Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    }
}
