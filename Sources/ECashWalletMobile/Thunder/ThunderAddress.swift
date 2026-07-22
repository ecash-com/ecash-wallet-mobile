// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Crypto   // SHA256 for the deposit-address checksum
import Blake3   // official BLAKE3 (the address hash)

/// A Thunder address: the first 20 bytes of `BLAKE3(ed25519_public_key)` (`authorization.rs::
/// get_address`), rendered as plain bitcoin-alphabet base58 with no checksum (`address.rs::as_base58`).
struct ThunderAddress: Equatable {
    /// The raw 20-byte address hash.
    let bytes: [UInt8]

    /// Derive from a 32-byte ed25519 public key.
    init(publicKey: [UInt8]) {
        let digest = Array(Blake3.hash(data: publicKey))   // 32-byte BLAKE3; Thunder keeps the first 20
        self.bytes = Array(digest.prefix(20))
    }

    /// Wrap a raw 20-byte hash (e.g. a decoded address).
    init(bytes: [UInt8]) {
        precondition(bytes.count == 20, "Thunder address is 20 bytes")
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
    /// This is the address our eCash BDK engine sends a deposit to; `sidechainNumber` is Thunder's
    /// `THIS_SIDECHAIN` (to be pinned when we wire deposits — see docs/thunder-sidechain-support.md).
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
