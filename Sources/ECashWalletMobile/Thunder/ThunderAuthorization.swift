// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One input authorization (thunder-rust `authorization::Authorization`): an ed25519 verifying key
/// (32 bytes) and its signature (64 bytes) over `borsh(transaction)`. Borsh encoding is the two fixed
/// arrays back to back — 96 bytes, no length prefix. Thunder pairs authorizations to inputs BY
/// POSITION, and separately requires `BLAKE3(verifying_key)[..20] == the spent output's address`
/// (`authorization::get_address`, which is exactly `ThunderAddress(publicKey:)`).
struct ThunderAuthorization: Equatable {
    let verifyingKey: [UInt8]   // 32-byte ed25519 public key
    let signature: [UInt8]      // 64-byte ed25519 signature

    func borshEncode(into w: inout BorshWriter) {
        w.writeFixedBytes(verifyingKey)   // [u8; 32]
        w.writeFixedBytes(signature)      // [u8; 64]
    }
}

/// A signed, submit-ready transaction — thunder-rust `AuthorizedTransaction` (= `Authorized<Transaction>`):
/// the transaction plus one `Authorization` per input, in input order. This is precisely the value the
/// (future) `submit_transaction` RPC accepts. Borsh = `borsh(transaction) ++ Vec<Authorization>`.
struct AuthorizedThunderTransaction: Equatable {
    let transaction: ThunderTransaction
    let authorizations: [ThunderAuthorization]

    /// Sign `transaction` into an `AuthorizedThunderTransaction`. `inputKeys[i]` MUST be the key that
    /// controls `transaction.inputs[i]` (its address == `inputKeys[i].address`) — Thunder checks each
    /// authorization against the spent output's address by position. Every input signs the SAME
    /// message, `borsh(transaction)` (Thunder has no per-input sighash), each with its own key. This
    /// is the only place the ed25519 secret is used; keys should be derived transiently here and
    /// dropped (Golden Rule §2).
    static func authorize(_ transaction: ThunderTransaction,
                          inputKeys: [ThunderKey]) throws -> AuthorizedThunderTransaction {
        guard inputKeys.count == transaction.inputs.count else {
            throw ThunderError.authorizationKeyCountMismatch(
                inputs: transaction.inputs.count, keys: inputKeys.count)
        }
        let message = transaction.borshEncoded()
        let authorizations = try inputKeys.map { key in
            ThunderAuthorization(verifyingKey: key.publicKeyBytes, signature: try key.sign(message))
        }
        return AuthorizedThunderTransaction(transaction: transaction, authorizations: authorizations)
    }

    /// Canonical Borsh encoding — byte-identical to thunder-rust `borsh::to_vec(&authorized_tx)`.
    func borshEncoded() -> [UInt8] {
        var w = BorshWriter()
        w.writeFixedBytes(transaction.borshEncoded())   // borsh(Transaction)
        w.writeU32(UInt32(authorizations.count))         // Vec<Authorization> length
        for authorization in authorizations { authorization.borshEncode(into: &w) }
        return w.bytes
    }
}
