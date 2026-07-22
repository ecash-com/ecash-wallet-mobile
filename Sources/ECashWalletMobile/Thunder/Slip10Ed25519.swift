// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// SLIP-0010 hierarchical key derivation for **ed25519** — matches thunder-rust's
/// `ed25519-dalek-bip32`. ed25519 supports ONLY hardened derivation, so every child index is
/// hardened. Each node is (32-byte key material, 32-byte chain code); the node's key material IS
/// the ed25519 secret seed a signing key is built from. Verified against the SLIP-0010 spec's
/// ed25519 test vectors (seed → master + derived keys/chain-codes/public-keys).
enum Slip10Ed25519 {
    struct Node {
        let key: [UInt8]        // 32-byte ed25519 secret seed (SLIP-0010 I_L)
        let chainCode: [UInt8]  // 32-byte chain code (SLIP-0010 I_R)
    }

    static let hardenedOffset: UInt32 = 0x8000_0000

    /// Master node from a BIP32/BIP39 seed: `HMAC-SHA512(key = "ed25519 seed", data = seed)`.
    static func master(seed: [UInt8]) -> Node {
        let i = ThunderCrypto.hmacSHA512(key: Array("ed25519 seed".utf8), data: seed)
        return Node(key: Array(i[0..<32]), chainCode: Array(i[32..<64]))
    }

    /// Hardened child: `HMAC-SHA512(chainCode, 0x00 || key || ser32(index'))`. `index` is the RAW
    /// index (e.g. `0`, `1`); the hardened offset is applied here since ed25519 is always hardened.
    static func hardenedChild(_ parent: Node, index: UInt32) -> Node {
        var data: [UInt8] = [0x00]
        data.append(contentsOf: parent.key)
        data.append(contentsOf: ser32(index | hardenedOffset))
        let i = ThunderCrypto.hmacSHA512(key: parent.chainCode, data: data)
        return Node(key: Array(i[0..<32]), chainCode: Array(i[32..<64]))
    }

    /// Derive down an all-hardened path of RAW indices (Thunder uses `[1, 0, 0, index]`).
    static func derive(seed: [UInt8], hardenedPath: [UInt32]) -> Node {
        var node = master(seed: seed)
        for index in hardenedPath { node = hardenedChild(node, index: index) }
        return node
    }

    /// Big-endian 4-byte serialization of a derivation index.
    private static func ser32(_ i: UInt32) -> [UInt8] {
        [UInt8((i >> 24) & 0xff), UInt8((i >> 16) & 0xff), UInt8((i >> 8) & 0xff), UInt8(i & 0xff)]
    }
}
