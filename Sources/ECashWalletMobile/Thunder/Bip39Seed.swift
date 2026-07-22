// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// BIP39 mnemonic → 64-byte seed: `PBKDF2-HMAC-SHA512(mnemonic, "mnemonic"+passphrase, 2048, 64)`,
/// with NFKD normalization per the spec. This is the SAME seed the Bitcoin/eCash (BDK) wallet derives
/// from — one mnemonic, two curves (secp256k1 for Bitcoin, ed25519 for Thunder) — so a single backup
/// covers both. Matches thunder-rust's `bip39` seed derivation. Verified against the BIP39 vectors.
///
/// Note: this does NOT validate the mnemonic's checksum/wordlist — generation and validation stay with
/// BDK's `Mnemonic` in WalletService; this only stretches an already-valid phrase into Thunder's seed.
enum Bip39Seed {
    static func seed(mnemonic: String, passphrase: String = "") -> [UInt8] {
        let password = Array(mnemonic.decomposedStringWithCompatibilityMapping.utf8)
        let salt = Array(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        return ThunderCrypto.pbkdf2HMACSHA512(
            password: password, salt: salt, iterations: 2048, derivedKeyLength: 64)
    }
}
