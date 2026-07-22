// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Bitcoin-alphabet Base58 (NO checksum, NO version byte) — matches thunder-rust's
/// `bitcoin::base58::encode`/`decode`, which Thunder uses verbatim for addresses (base58 of the
/// 20-byte BLAKE3 digest; see `types/address.rs::as_base58`). Hand-written and dependency-free so
/// the whole Thunder key stack is one auditable place; byte-for-byte test-vector'd (Bitcoin Core's
/// `base58_encode_decode.json`).
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let decodeMap: [Int8] = {
        var map = [Int8](repeating: -1, count: 128)
        for (i, c) in alphabet.enumerated() { map[Int(c)] = Int8(i) }
        return map
    }()

    static func encode(_ input: [UInt8]) -> String {
        var zeros = 0
        while zeros < input.count && input[zeros] == 0 { zeros += 1 }
        // Upper bound on output length: ceil(log(256)/log(58) · n) ≈ n · 138/100 + 1.
        let size = (input.count - zeros) * 138 / 100 + 1
        var b58 = [UInt8](repeating: 0, count: size)
        var length = 0
        for idx in zeros..<input.count {
            var carry = Int(input[idx])
            var i = 0
            var k = size - 1
            while (carry != 0 || i < length) && k >= 0 {
                carry += 256 * Int(b58[k])
                b58[k] = UInt8(carry % 58)
                carry /= 58
                i += 1
                k -= 1
            }
            length = i
        }
        var it = size - length
        while it < size && b58[it] == 0 { it += 1 }
        var result = [UInt8](repeating: alphabet[0], count: zeros)   // one '1' per leading zero byte
        while it < size {
            result.append(alphabet[Int(b58[it])])
            it += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Decode; returns nil on an out-of-alphabet character.
    static func decode(_ string: String) -> [UInt8]? {
        let chars = Array(string.utf8)
        var zeros = 0
        while zeros < chars.count && chars[zeros] == alphabet[0] { zeros += 1 }
        // Upper bound: ceil(log(58)/log(256) · n) ≈ n · 733/1000 + 1.
        let size = (chars.count - zeros) * 733 / 1000 + 1
        var b256 = [UInt8](repeating: 0, count: size)
        var length = 0
        for idx in zeros..<chars.count {
            let c = chars[idx]
            if c >= 128 { return nil }
            let digit = decodeMap[Int(c)]
            if digit < 0 { return nil }
            var carry = Int(digit)
            var i = 0
            var k = size - 1
            while (carry != 0 || i < length) && k >= 0 {
                carry += 58 * Int(b256[k])
                b256[k] = UInt8(carry % 256)
                carry /= 256
                i += 1
                k -= 1
            }
            length = i
        }
        var it = size - length
        var result = [UInt8](repeating: 0, count: zeros)   // one 0x00 per leading '1'
        while it < size {
            result.append(b256[it])
            it += 1
        }
        return result
    }
}
