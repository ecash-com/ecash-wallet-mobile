// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One Thunder address key (thunder-rust ≥ 0.18): a ristretto255 scalar at `m/43'/1899'/0'/9'/0'/index`,
/// its public key, and the address it controls. Signs with FROST(ristretto255) Schnorr.
///
/// Holds a SECRET. Derive it only at signing time and drop it straight after (Golden Rule §2) — listing
/// addresses never needs one (`ThunderWallet.addresses(account:indices:)` derives from the public key).
struct ThunderKey {
    static let scheme = RistrettoSidechainKeyScheme.thunder

    let index: UInt32
    /// 32-byte scalar, little-endian, reduced mod ℓ.
    let secret: [UInt8]
    /// 32-byte compressed ristretto255 public key (the `verifying_key` in each input's `Authorization`).
    let publicKeyBytes: [UInt8]
    let address: ThunderAddress

    /// Derive the key at `index` from a BIP39 mnemonic (optional passphrase).
    static func derive(mnemonic: String, passphrase: String = "", index: UInt32) throws -> ThunderKey {
        try derive(seed: Bip39Seed.seed(mnemonic: mnemonic, passphrase: passphrase), index: index)
    }

    /// Derive the key at `index` from an already-computed BIP39 seed.
    static func derive(seed: [UInt8], index: UInt32) throws -> ThunderKey {
        try derive(account: scheme.accountKey(seed: seed), index: index)
    }

    /// Derive the key at `index` from the account key. For many indices — resolving which key owns each
    /// input — compute `scheme.accountKey(seed:)` once and call this per index: the five hardened
    /// account levels (and the 2048-round PBKDF2 before them) then run once, not per address.
    static func derive(account: RistrettoBip32.PrivateKey, index: UInt32) throws -> ThunderKey {
        let secret = try scheme.signingKey(account: account, index: index)
        let publicKey = try RistrettoBip32.PrivateKey(scalar: secret, chainCode: []).publicKey.point
        return ThunderKey(index: index, secret: secret, publicKeyBytes: publicKey,
                          address: ThunderAddress(publicKey: publicKey))
    }

    /// Sign a message — for Thunder, the borsh-encoded transaction — producing the 64-byte `R ‖ z`
    /// signature that goes into each input's `Authorization`. Always a fresh random nonce.
    func sign(_ message: [UInt8]) throws -> [UInt8] {
        try FrostSchnorr.sign(message: message, secret: secret)
    }
}
