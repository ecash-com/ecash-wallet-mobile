// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Crypto   // Apple's swift-crypto — same HMAC-SHA512 on iOS (CryptoKit) and Android (Fuse)

/// Low-level crypto primitives the Thunder key stack builds on, all on swift-crypto so iOS and
/// Android share one implementation. Kept tiny and test-vector'd — this is consensus-adjacent code.
enum ThunderCrypto {
    /// HMAC-SHA512 → 64 bytes. The workhorse of both SLIP-0010 and PBKDF2 below.
    static func hmacSHA512(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA512>.authenticationCode(for: Data(data), using: SymmetricKey(data: Data(key))))
    }

    /// PBKDF2-HMAC-SHA512 (RFC 2898). BIP39 uses this to stretch a mnemonic into the 64-byte seed
    /// (2048 rounds). Hand-rolled on `hmacSHA512` so we stay in the base `Crypto` module (no
    /// `_CryptoExtras` dependency); verified against the BIP39 test vectors.
    static func pbkdf2HMACSHA512(password: [UInt8], salt: [UInt8],
                                 iterations: Int, derivedKeyLength: Int) -> [UInt8] {
        precondition(iterations > 0 && derivedKeyLength > 0)
        let hLen = 64
        let key = SymmetricKey(data: Data(password))
        var derived = [UInt8]()
        derived.reserveCapacity(derivedKeyLength)
        var blockIndex: UInt32 = 1
        while derived.count < derivedKeyLength {
            // T_n = F(password, salt, c, n): U1 = HMAC(pw, salt || INT32BE(n)); then XOR-fold U2..Uc.
            var message = salt
            message.append(UInt8((blockIndex >> 24) & 0xff))
            message.append(UInt8((blockIndex >> 16) & 0xff))
            message.append(UInt8((blockIndex >> 8) & 0xff))
            message.append(UInt8(blockIndex & 0xff))
            var u = Array(HMAC<SHA512>.authenticationCode(for: Data(message), using: key))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA512>.authenticationCode(for: Data(u), using: key))
                    for i in 0..<hLen { t[i] ^= u[i] }
                }
            }
            derived.append(contentsOf: t)
            blockIndex += 1
        }
        return Array(derived.prefix(derivedKeyLength))
    }
}
