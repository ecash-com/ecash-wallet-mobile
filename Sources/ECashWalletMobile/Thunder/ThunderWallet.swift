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

    /// The BIP39 seed for this mnemonic. PBKDF2 (2048 iterations) — compute it once and pass it to the
    /// batch helpers rather than re-deriving per index.
    func seed() -> [UInt8] { Bip39Seed.seed(mnemonic: mnemonic, passphrase: passphrase) }

    /// The key at derivation index `index` (`m/1'/0'/0'/index'`).
    func key(at index: UInt32) throws -> ThunderKey {
        try ThunderKey.derive(mnemonic: mnemonic, passphrase: passphrase, index: index)
    }

    /// The address at derivation index `index`.
    func address(at index: UInt32) throws -> ThunderAddress {
        try key(at: index).address
    }

    /// The first `count` addresses (indices `0 ..< count`), from a single seed computation.
    func addresses(count: Int) throws -> [ThunderAddress] {
        let seed = seed()
        return try (0..<count).map { try ThunderKey.derive(seed: seed, index: UInt32($0)).address }
    }

    /// Resolve the key controlling `address` by scanning indices `0 ..< searchLimit`; nil if none
    /// matches (the wallet doesn't own it, or it's derived beyond the limit).
    func key(for address: ThunderAddress, searchLimit: Int = defaultAddressSearchLimit) throws -> ThunderKey? {
        try keys(for: [address], searchLimit: searchLimit)[address]
    }

    /// Resolve the keys controlling `addresses` in ONE scan of indices `0 ..< searchLimit` — the shape
    /// signing actually needs, since a transaction usually spends several of our addresses at once.
    /// Scanning once per address instead would repeat the whole derivation for each input.
    /// Addresses we don't own are simply absent from the result.
    func keys(for addresses: [ThunderAddress],
              searchLimit: Int = defaultAddressSearchLimit) throws -> [ThunderAddress: ThunderKey] {
        var wanted = Set(addresses)
        guard !wanted.isEmpty else { return [:] }
        let seed = seed()
        var found: [ThunderAddress: ThunderKey] = [:]
        for index in 0..<searchLimit {
            let candidate = try ThunderKey.derive(seed: seed, index: UInt32(index))
            if wanted.remove(candidate.address) != nil {
                found[candidate.address] = candidate
                if wanted.isEmpty { break }
            }
        }
        return found
    }

    /// Build the submit-ready authorized transaction from a locally-constructed transaction and the
    /// address each input spends (`inputAddresses[i]` is the address of `transaction.inputs[i]`'s UTXO,
    /// known from the `get_utxos` we selected from). Resolves each input's key by address, then signs.
    /// The phone owns coin-selection + tx construction + signing; the node only fills the utreexo proof
    /// at `submit_transaction` (decided 2026-07-23). We build the tx with an empty proof — it's
    /// `#[borsh(skip)]`, so it's absent from the signed bytes regardless.
    func authorize(_ transaction: ThunderTransaction,
                   inputAddresses: [ThunderAddress],
                   searchLimit: Int = defaultAddressSearchLimit) throws -> AuthorizedThunderTransaction {
        guard inputAddresses.count == transaction.inputs.count else {
            throw ThunderError.inputAddressCountMismatch(
                inputs: transaction.inputs.count, addresses: inputAddresses.count)
        }
        // One scan for every input address, not one scan per input.
        let byAddress = try keys(for: inputAddresses, searchLimit: searchLimit)
        var inputKeys: [ThunderKey] = []
        inputKeys.reserveCapacity(inputAddresses.count)
        for (index, address) in inputAddresses.enumerated() {
            guard let key = byAddress[address] else {
                throw ThunderError.noKeyForInputAddress(inputIndex: index)
            }
            inputKeys.append(key)
        }
        return try AuthorizedThunderTransaction.authorize(transaction, inputKeys: inputKeys)
    }
}
