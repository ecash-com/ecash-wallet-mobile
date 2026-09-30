// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Crypto   // SHA256 for the deposit-address checksum
import Blake3   // official BLAKE3 (the address hash)

/// A sidechain address, shared by L2L's Rust sidechains (Thunder, Truthcoin, Coinshift): the first 20
/// bytes of `BLAKE3-XOF(compressed public key)` (thunder-rust `authorization.rs::get_address`), rendered
/// as plain bitcoin-alphabet base58 with no checksum (`address.rs::as_base58`). The XOF's first 32 bytes
/// ARE plain BLAKE3, so hashing and truncating is the same thing.
struct SidechainAddress: Equatable, Hashable {
    /// The raw 20-byte address hash.
    let bytes: [UInt8]

    /// Derive from a 32-byte public key (a compressed ristretto255 point on every current sidechain).
    init(publicKey: [UInt8]) {
        let digest = Array(Blake3.hash(data: publicKey))   // 32-byte BLAKE3; the address is the first 20
        self.bytes = Array(digest.prefix(20))
    }

    /// Wrap a raw 20-byte hash (e.g. a decoded address).
    init(bytes: [UInt8]) {
        precondition(bytes.count == 20, "sidechain address is 20 bytes")
        self.bytes = bytes
    }

    /// Parse a plain-base58 address; nil if it isn't valid base58 of exactly 20 bytes.
    init?(base58 string: String) {
        guard let decoded = Base58.decode(string), decoded.count == 20 else { return nil }
        self.bytes = decoded
    }

    /// The everyday address string a user sees / pastes (plain base58, no checksum).
    var base58: String { Base58.encode(bytes) }

    /// The **mainchain** deposit form for sidechain `sidechainNumber`:
    /// `s{n}_{base58}_{hex(sha256("s{n}_{base58}_")[..3])}` (`address.rs::format_for_deposit`).
    func depositString(sidechainNumber: Int) -> String {
        let prefix = "s\(sidechainNumber)_\(base58)_"
        let digest = Array(SHA256.hash(data: Data(prefix.utf8)))
        let hexChars = Array("0123456789abcdef".utf8)
        var check = [UInt8]()
        for b in digest.prefix(3) {
            check.append(hexChars[Int(b >> 4)])
            check.append(hexChars[Int(b & 0x0f)])
        }
        return prefix + String(decoding: check, as: UTF8.self)
    }
}

/// Thunder's addresses are plain sidechain addresses; the name stays for readability at Thunder call sites.
typealias ThunderAddress = SidechainAddress
