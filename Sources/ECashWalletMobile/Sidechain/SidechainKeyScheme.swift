// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// How one sidechain turns a BIP39 seed into address keys. This is the part that differs per sidechain
/// (docs/thunder-key-port.md §3): Thunder and Coinshift use ristretto255 bip32ish on the same path shape
/// but disagree on the bias fix; Truthcoin derives with secp256k1 BIP32 instead. Everything downstream —
/// FROST signing, addresses, deposit strings — is shared.
protocol SidechainKeyScheme {
    /// The sidechain's slot on the mainchain (`THIS_SIDECHAIN`); also the deposit-string prefix.
    var sidechainNumber: Int { get }

    /// The 32-byte signing scalar for address `index`.
    func signingKey(seed: [UInt8], index: UInt32) throws -> [UInt8]
}

/// A scheme whose address keys also derive from PUBLIC data, so a wallet can list addresses and sync
/// without loading its seed (watch-only, like BDK's public descriptors). The ristretto bip32ish sidechains
/// qualify; Truthcoin's secp256k1-then-reinterpret derivation does not.
protocol WatchOnlySidechainKeyScheme: SidechainKeyScheme {
    /// The account-level public key that address keys derive from without the seed — the "xpub".
    func accountPublicKey(seed: [UInt8]) throws -> RistrettoBip32.PublicKey

    /// The 32-byte public key for address `index`, from the account public key alone.
    func publicKey(account: RistrettoBip32.PublicKey, index: UInt32) throws -> [UInt8]
}

/// ristretto255 bip32ish on `m/43'/1899'/0'/<sidechain>'/0'/index` — the path thunder-rust and
/// coinshift-rs both use (`lib/wallet/mod.rs::get_signing_key`): bip43 purpose / eCash token / purpose 0 /
/// sidechain / account 0 / address index. The account levels are hardened; the address index is
/// non-hardened below 2^31 (hardened at or above, as `bip32ish::ChildIndex::from` maps it).
struct RistrettoSidechainKeyScheme: WatchOnlySidechainKeyScheme {
    let sidechainNumber: Int
    /// thunder-rust ≥ 0.18 (6b4a25f) clears the top 3 bits before reducing; coinshift-rs doesn't.
    let biasFix: Bool

    /// The account levels, unhardened (each is hardened when derived).
    private var accountLevels: [UInt32] { [43, 1899, 0, UInt32(sidechainNumber), 0] }

    private var accountPath: [UInt32] {
        accountLevels.map { $0 | RistrettoBip32.hardenedOffset }
    }

    /// The printable path of address `index`, e.g. `m/43'/1899'/0'/9'/0'/5` — for display only.
    func derivationPath(index: Int32) -> String {
        "m/" + accountLevels.map { "\($0)'" }.joined(separator: "/") + "/\(index)"
    }

    func accountKey(seed: [UInt8]) throws -> RistrettoBip32.PrivateKey {
        try RistrettoBip32.derive(try RistrettoBip32.master(seed: seed, biasFix: biasFix),
                                  path: accountPath, biasFix: biasFix)
    }

    func accountPublicKey(seed: [UInt8]) throws -> RistrettoBip32.PublicKey {
        try accountKey(seed: seed).publicKey
    }

    func signingKey(seed: [UInt8], index: UInt32) throws -> [UInt8] {
        try signingKey(account: accountKey(seed: seed), index: index)
    }

    /// For deriving many indices: compute `accountKey(seed:)` once, then call this per index.
    func signingKey(account: RistrettoBip32.PrivateKey, index: UInt32) throws -> [UInt8] {
        try RistrettoBip32.derive(account, index: index, biasFix: biasFix).scalar
    }

    func publicKey(account: RistrettoBip32.PublicKey, index: UInt32) throws -> [UInt8] {
        try RistrettoBip32.derive(account, index: index, biasFix: biasFix).point
    }
}

extension RistrettoSidechainKeyScheme {
    /// Thunder, slot 9 (thunder-rust ≥ 0.18).
    static let thunder = RistrettoSidechainKeyScheme(sidechainNumber: 9, biasFix: true)
}
