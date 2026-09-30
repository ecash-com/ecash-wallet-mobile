// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Crypto        // SHA-512
import Ristretto255

/// Single-signer FROST(ristretto255, SHA-512) Schnorr — what L2L's Rust sidechains sign transactions with
/// (`frost_ristretto255::SigningKey::sign`, frost-core `default_sign`, rev 0966bd1):
///
///     R = k·G,   c = H2(R ‖ PK ‖ msg),   z = k + c·sk,   signature = R ‖ z   (64 bytes)
///     H2(m) = SHA-512("FROST-RISTRETTO255-SHA512-v1" ‖ "chal" ‖ m) mod ℓ   (RFC 9591 §6.2)
///
/// Only the single-signer path — no threshold rounds. The message is whatever the sidechain signs
/// (Thunder: `borsh(tx)`; Truthcoin prefixes a domain byte), so callers pass it complete.
enum FrostSchnorr {
    static let signatureBytes = 64

    enum Error: Swift.Error, Equatable { case zeroNonce }

    /// Sign `message` with `secret` (32-byte scalar). `nonce` exists for known-answer tests ONLY —
    /// production signing always draws a fresh random `k`; reusing one reveals the key.
    static func sign(message: [UInt8], secret: [UInt8], nonce: [UInt8]? = nil) throws -> [UInt8] {
        let publicKey = try Ristretto255.baseMul(secret)
        let k = try nonce ?? randomNonzeroScalar()
        let r = try Ristretto255.baseMul(k)
        let c = try challenge(r: r, publicKey: publicKey, message: message)
        return r + (try Ristretto255.scalarAdd(k, Ristretto255.scalarMul(c, secret)))
    }

    /// `z·G == R + c·PK`. Rejects non-canonical `z` and invalid points, as frost-core does.
    static func verify(signature: [UInt8], publicKey: [UInt8], message: [UInt8]) -> Bool {
        guard signature.count == signatureBytes, Ristretto255.isValidPoint(publicKey) else { return false }
        let r = Array(signature[0..<32]), z = Array(signature[32..<64])
        guard Ristretto255.isValidPoint(r), (try? Ristretto255.reduce(z)) == z,
              let c = try? challenge(r: r, publicKey: publicKey, message: message),
              let lhs = try? Ristretto255.baseMul(z),
              let rhs = try? Ristretto255.add(r, Ristretto255.mul(c, publicKey)) else { return false }
        return lhs == rhs
    }

    static func challenge(r: [UInt8], publicKey: [UInt8], message: [UInt8]) throws -> [UInt8] {
        var hasher = SHA512()
        hasher.update(data: Array("FROST-RISTRETTO255-SHA512-v1".utf8))
        hasher.update(data: Array("chal".utf8))
        hasher.update(data: r)
        hasher.update(data: publicKey)
        hasher.update(data: message)
        return try Ristretto255.reduce(wide: Array(hasher.finalize()))
    }

    /// A uniformly random nonzero scalar from the system CSPRNG (64 random bytes reduced mod ℓ, as
    /// frost-core's `random_nonzero` does).
    private static func randomNonzeroScalar() throws -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<8 {
            let wide = (0..<64).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
            let k = try Ristretto255.reduce(wide: wide)
            if k.contains(where: { $0 != 0 }) { return k }
        }
        throw Error.zeroNonce
    }
}
