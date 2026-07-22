// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A Thunder key set derived from one BIP39 mnemonic — the seed-holding component that derives
/// addresses and signs.
///
/// **Why this isn't watch-only:** SLIP-0010 ed25519 derivation is ALL-HARDENED (`m/1'/0'/0'/i'`), so
/// — unlike BDK's secp256k1 xpub — a child public key can't be derived without the parent private key.
/// There is no Thunder "watch-only xpub": deriving the address set itself requires the seed. The
/// engine's watch-only surface is therefore a *cache* of already-derived public addresses; this type
/// is the thing that produces/extends that cache and signs, and like the BDK path it should be created
/// transiently at those moments and dropped, never persisted (Golden Rule §2 / docs/key-storage.md).
struct ThunderWallet {
    let mnemonic: String
    let passphrase: String

    /// How many consecutive indices to scan when resolving an address → key by default.
    static let defaultAddressSearchLimit = 100

    init(mnemonic: String, passphrase: String = "") {
        self.mnemonic = mnemonic
        self.passphrase = passphrase
    }

    /// The key at derivation index `index` (`m/1'/0'/0'/index'`).
    func key(at index: UInt32) throws -> ThunderKey {
        try ThunderKey.derive(mnemonic: mnemonic, passphrase: passphrase, index: index)
    }

    /// The address at derivation index `index`.
    func address(at index: UInt32) throws -> ThunderAddress {
        try key(at: index).address
    }

    /// The first `count` addresses (indices `0 ..< count`).
    func addresses(count: Int) throws -> [ThunderAddress] {
        try (0..<count).map { try address(at: UInt32($0)) }
    }

    /// Resolve the key controlling `address` by scanning indices `0 ..< searchLimit`; nil if none
    /// matches (the wallet doesn't own it, or it's derived beyond the limit).
    func key(for address: ThunderAddress, searchLimit: Int = defaultAddressSearchLimit) throws -> ThunderKey? {
        for index in 0..<searchLimit {
            let candidate = try key(at: UInt32(index))
            if candidate.address == address { return candidate }
        }
        return nil
    }

    /// Build the submit-ready authorized transaction from a node-provided unsigned transaction and the
    /// address each input spends (`inputAddresses[i]` is the address of `transaction.inputs[i]`'s UTXO,
    /// which the RPC reports). Resolves each input's key by address, then signs. This is the full local
    /// half of a send: the node owns coin-selection + utreexo proof; we own only the ed25519 signing.
    func authorize(_ transaction: ThunderTransaction,
                   inputAddresses: [ThunderAddress],
                   searchLimit: Int = defaultAddressSearchLimit) throws -> AuthorizedThunderTransaction {
        guard inputAddresses.count == transaction.inputs.count else {
            throw ThunderError.inputAddressCountMismatch(
                inputs: transaction.inputs.count, addresses: inputAddresses.count)
        }
        var keys: [ThunderKey] = []
        keys.reserveCapacity(inputAddresses.count)
        for (index, address) in inputAddresses.enumerated() {
            guard let key = try key(for: address, searchLimit: searchLimit) else {
                throw ThunderError.noKeyForInputAddress(inputIndex: index)
            }
            keys.append(key)
        }
        return try AuthorizedThunderTransaction.authorize(transaction, inputKeys: keys)
    }
}
