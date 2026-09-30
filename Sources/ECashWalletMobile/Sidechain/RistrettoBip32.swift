// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Ristretto255

/// BIP32-style hierarchical derivation over ristretto255 — the "bip32ish" scheme L2L's Rust sidechains
/// use (thunder-rust `lib/wallet/bip32.rs`, coinshift-rs the same file minus the bias fix).
///
/// - Master: `I = HMAC-SHA512("Bitcoin seed", seed)`; secret = scalar(I[..32]), chain code = I[32..].
/// - Hardened child `i ≥ 2^31`: `I = HMAC-SHA512(cc, 0x00 ‖ secret_le ‖ be32(i))`.
/// - Non-hardened child: `I = HMAC-SHA512(cc, compressed(secret·G) ‖ be32(i))`.
/// - Child secret = parent + scalar(I[..32]) mod ℓ; child chain code = I[32..].
///
/// `scalar(·)` reads the 32 bytes **big-endian** and reduces mod ℓ. With `biasFix` (Thunder ≥ 0.18,
/// commit 6b4a25f) the top 3 bits are cleared first; coinshift-rs predates that fix. Same seed, different
/// keys — so the flag is part of each sidechain's key scheme, never a default to guess at.
///
/// Non-hardened derivation also works from the **public** side (`child_pk = parent_pk + tweak·G`), which
/// is what lets a wallet list addresses without its seed.
enum RistrettoBip32 {
    static let hardenedOffset: UInt32 = 0x8000_0000

    struct PrivateKey: Equatable {
        /// 32 bytes, little-endian, reduced mod ℓ.
        let scalar: [UInt8]
        let chainCode: [UInt8]

        var publicKey: PublicKey {
            get throws { PublicKey(point: try Ristretto255.baseMul(scalar), chainCode: chainCode) }
        }
    }

    /// The public half of an extended key: enough to derive non-hardened children, never to sign.
    struct PublicKey: Equatable, Codable {
        /// Compressed ristretto255 point, 32 bytes.
        let point: [UInt8]
        let chainCode: [UInt8]
    }

    enum Error: Swift.Error, Equatable {
        /// Public derivation can't produce a hardened child.
        case hardenedPublicDerivation
    }

    static func master(seed: [UInt8], biasFix: Bool) throws -> PrivateKey {
        let i = SidechainHash.hmacSHA512(key: Array("Bitcoin seed".utf8), data: seed)
        return PrivateKey(scalar: try scalar(fromBigEndian: Array(i[0..<32]), biasFix: biasFix),
                          chainCode: Array(i[32..<64]))
    }

    static func derive(_ parent: PrivateKey, index: UInt32, biasFix: Bool) throws -> PrivateKey {
        let data: [UInt8]
        if index >= hardenedOffset {
            data = [0x00] + parent.scalar + bigEndian(index)
        } else {
            data = try Ristretto255.baseMul(parent.scalar) + bigEndian(index)
        }
        let i = SidechainHash.hmacSHA512(key: parent.chainCode, data: data)
        let tweak = try scalar(fromBigEndian: Array(i[0..<32]), biasFix: biasFix)
        return PrivateKey(scalar: try Ristretto255.scalarAdd(parent.scalar, tweak), chainCode: Array(i[32..<64]))
    }

    static func derive(_ key: PrivateKey, path: [UInt32], biasFix: Bool) throws -> PrivateKey {
        try path.reduce(key) { try derive($0, index: $1, biasFix: biasFix) }
    }

    /// Non-hardened child of a public key. Equals `derive(parentPrivate, index:).publicKey`.
    static func derive(_ parent: PublicKey, index: UInt32, biasFix: Bool) throws -> PublicKey {
        guard index < hardenedOffset else { throw Error.hardenedPublicDerivation }
        let i = SidechainHash.hmacSHA512(key: parent.chainCode, data: parent.point + bigEndian(index))
        let tweak = try scalar(fromBigEndian: Array(i[0..<32]), biasFix: biasFix)
        return PublicKey(point: try Ristretto255.add(parent.point, Ristretto255.baseMul(tweak)),
                         chainCode: Array(i[32..<64]))
    }

    /// thunder-rust `scalar_from_uniform_be_bytes` (`biasFix`) / coinshift-rs `scalar_from_be_bytes`.
    static func scalar(fromBigEndian bytes: [UInt8], biasFix: Bool) throws -> [UInt8] {
        var b = bytes
        if biasFix { b[0] &= 0b0001_1111 }
        return try Ristretto255.reduce(Array(b.reversed()))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}
