// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A Thunder key set derived from one BIP39 mnemonic — the seed-holding component that signs.
///
/// **Addresses don't need it.** Since thunder-rust 0.18, address keys are NON-hardened children of the
/// account key (`m/43'/1899'/0'/9'/0'/i`), so the account *public* key lists every address
/// (`addresses(account:indices:)`) — the watch-only model the BDK side already uses. This type is for
/// the moments that need the secret: producing that account public key once, and signing. Create it
/// transiently at those moments and drop it, never persist it (Golden Rule §2 / docs/key-storage.md).
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

    /// The key at derivation index `index` (`m/43'/1899'/0'/9'/0'/index`).
    func key(at index: UInt32) throws -> ThunderKey {
        try ThunderKey.derive(mnemonic: mnemonic, passphrase: passphrase, index: index)
    }

    /// The address at derivation index `index`.
    func address(at index: UInt32) throws -> ThunderAddress {
        try key(at: index).address
    }

    /// The first `count` addresses (indices `0 ..< count`), from a single seed computation.
    func addresses(count: Int) throws -> [ThunderAddress] {
        try addresses(indices: UInt32(0)..<UInt32(count))
    }

    /// The addresses at `indices`, from a single seed computation. Gap-limit discovery walks *past*
    /// the known window in batches, so it needs an arbitrary range rather than a 0-based prefix.
    func addresses(indices: Range<UInt32>) throws -> [ThunderAddress] {
        try Self.addresses(account: accountPublicKey(), indices: indices)
    }

    /// The account public key ("xpub") every address derives from. Public, but privacy-sensitive like
    /// any xpub: it links all of the wallet's addresses.
    func accountPublicKey() throws -> RistrettoBip32.PublicKey {
        try ThunderKey.scheme.accountPublicKey(seed: seed())
    }

    /// The addresses at `indices`, from the account public key alone — no seed, no secret.
    static func addresses(account: RistrettoBip32.PublicKey, indices: Range<UInt32>) throws -> [ThunderAddress] {
        try indices.map { ThunderAddress(publicKey: try ThunderKey.scheme.publicKey(account: account, index: $0)) }
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
        let account = try ThunderKey.scheme.accountKey(seed: seed())
        var found: [ThunderAddress: ThunderKey] = [:]
        for index in 0..<searchLimit {
            let candidate = try ThunderKey.derive(account: account, index: UInt32(index))
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
