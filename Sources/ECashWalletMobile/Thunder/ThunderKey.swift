// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Crypto   // Curve25519.Signing = ed25519

/// A derived Thunder key: the ed25519 signing key at `m/1'/0'/0'/index'` (all hardened, per
/// thunder-rust's `wallet.rs`), plus its public key and address. Built from a BIP39 mnemonic — the
/// SAME seed as the Bitcoin/eCash wallet, so one backup covers both curves.
///
/// This is the Thunder analog of a BDK-derived key. It is deliberately the ONLY place the ed25519
/// secret exists; like the BDK path, callers should derive it transiently at sign time and drop it —
/// never persist the signing key (Golden Rule §2 / docs/key-storage.md).
struct ThunderKey {
    let index: UInt32
    let signingKey: Curve25519.Signing.PrivateKey
    let publicKeyBytes: [UInt8]       // 32-byte ed25519 verifying key
    let address: ThunderAddress

    /// Thunder's account path prefix `m/1'/0'/0'` (the key index is appended), all hardened.
    static let accountPath: [UInt32] = [1, 0, 0]

    /// Derive the key at `index` from a BIP39 mnemonic (optional passphrase).
    static func derive(mnemonic: String, passphrase: String = "", index: UInt32) throws -> ThunderKey {
        let seed = Bip39Seed.seed(mnemonic: mnemonic, passphrase: passphrase)
        let node = Slip10Ed25519.derive(seed: seed, hardenedPath: accountPath + [index])
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: node.key)
        let publicKey = Array(signingKey.publicKey.rawRepresentation)
        return ThunderKey(index: index, signingKey: signingKey,
                          publicKeyBytes: publicKey, address: ThunderAddress(publicKey: publicKey))
    }

    /// ed25519-sign a message. Thunder signs the borsh-encoded transaction body (§ Borsh, upcoming),
    /// producing the 64-byte signature that goes into each input's `Authorization`.
    func sign(_ message: [UInt8]) throws -> [UInt8] {
        Array(try signingKey.signature(for: Data(message)))
    }
}
