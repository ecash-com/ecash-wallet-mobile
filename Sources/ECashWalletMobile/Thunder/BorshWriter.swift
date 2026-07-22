// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A minimal Borsh serializer (https://borsh.io) — just the pieces Thunder's `Transaction` needs.
/// Borsh is deterministic and length-prefixed: integers are little-endian fixed-width, a `Vec<T>` or
/// byte-slice is prefixed with a u32 LE length, and a fixed array `[u8; N]` is written raw. This
/// produces bytes identical to thunder-rust's `borsh::to_vec` — the whole point, since those bytes are
/// what gets ed25519-signed and BLAKE3-hashed. Consensus-critical; keep it dead simple.
struct BorshWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeU8(_ v: UInt8) { bytes.append(v) }

    mutating func writeU32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff))
        bytes.append(UInt8((v >> 24) & 0xff))
    }

    mutating func writeU64(_ v: UInt64) {
        var x = v
        for _ in 0..<8 { bytes.append(UInt8(x & 0xff)); x >>= 8 }
    }

    /// A fixed-size byte array (`[u8; N]`): written raw, no length prefix.
    mutating func writeFixedBytes(_ b: [UInt8]) { bytes.append(contentsOf: b) }

    /// A variable-length byte sequence (`Vec<u8>` / `&[u8]`): u32 LE length, then the bytes.
    mutating func writeVarBytes(_ b: [UInt8]) {
        writeU32(UInt32(b.count))
        bytes.append(contentsOf: b)
    }
}
