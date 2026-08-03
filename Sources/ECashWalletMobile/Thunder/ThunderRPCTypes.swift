// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// JSON shapes for the Thunder node's JSON-RPC — hand-written to match what thunder-rust's **serde**
/// actually emits, verified against the `types` crate on branch `2026-07-24-refactor`.
///
/// ⚠️ **Do not generate these from the node's OpenAPI schema — it is wrong in two places**, because the
/// `#[schema(value_type = …)]` annotations disagree with the derived serde impls:
///   * `Transaction.inputs` is annotated `Vec<(OutPoint, String)>` but `Hash` is a bare `[u8; 32]` with
///     no hex wrapper, so serde emits an **array of 32 numbers**.
///   * `Authorization.verifying_key` / `.signature` are annotated `String`, but ed25519-dalek 2.2
///     serializes via `serializer.serialize_bytes` (no `serdect`/`serde_bytes` in the dependency
///     graph), so those are **arrays of 32 / 64 numbers** too. Its `Deserialize` implements
///     `visit_bytes` and `visit_seq` but *not* `visit_str`, so a hex string would be rejected outright
///     — arrays aren't a preference here, they're the only thing that works.
/// Types that *do* carry a serde hex/string wrapper: `Txid`/`MerkleRoot`/`BlockHash`
/// (`hexstr_human_readable`, raw byte order — NOT reversed) and `Address` (base58).
enum ThunderHex {
    static func encode(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return out
    }

    static func decode(_ string: String) -> [UInt8]? {
        let chars = Array(string)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    private static func nibble(_ c: Character) -> UInt8? {
        switch c {
        case "0"..."9": return UInt8(c.asciiValue! - 48)
        case "a"..."f": return UInt8(c.asciiValue! - 87)
        case "A"..."F": return UInt8(c.asciiValue! - 55)
        default: return nil
        }
    }
}

// MARK: - OutPoint

/// `types::OutPoint` over JSON — an externally-tagged Rust enum, so exactly one key:
/// `{"Regular":{"txid":"<hex>","vout":0}}` · `{"Coinbase":{"merkle_root":"<hex>","vout":0}}` ·
/// `{"Deposit":{"txid":"<hex>","vout":0}}`.
///
/// **Byte-order trap in `Deposit`:** its payload is a *mainchain* `bitcoin::OutPoint`, and
/// `bitcoin::Txid` serializes as its **display** hex — byte-REVERSED relative to the internal bytes we
/// Borsh-encode. Thunder's own `Txid` (in `Regular`) is the opposite: `const_hex` over the raw bytes,
/// no reversal. We convert on the `Deposit` boundary only, so the Borsh side always holds internal
/// order. Getting this backwards would produce a valid-looking input whose utxo hash is wrong.
struct ThunderRPCOutPoint: Codable, Equatable {
    let outPoint: ThunderOutPoint

    init(_ outPoint: ThunderOutPoint) { self.outPoint = outPoint }

    private enum Tag: String, CodingKey { case regular = "Regular", coinbase = "Coinbase", deposit = "Deposit" }
    private enum RegularKeys: String, CodingKey { case txid, vout }
    private enum CoinbaseKeys: String, CodingKey { case merkleRoot = "merkle_root", vout }
    private enum DepositKeys: String, CodingKey { case txid, vout }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Tag.self)
        if let regular = try? container.nestedContainer(keyedBy: RegularKeys.self, forKey: .regular) {
            let hex = try regular.decode(String.self, forKey: .txid)
            guard let txid = ThunderHex.decode(hex), txid.count == 32 else {
                throw ThunderRPCError.malformedResponse("outpoint txid")
            }
            outPoint = .regular(txid: txid, vout: try regular.decode(UInt32.self, forKey: .vout))
        } else if let coinbase = try? container.nestedContainer(keyedBy: CoinbaseKeys.self, forKey: .coinbase) {
            let hex = try coinbase.decode(String.self, forKey: .merkleRoot)
            guard let root = ThunderHex.decode(hex), root.count == 32 else {
                throw ThunderRPCError.malformedResponse("outpoint merkle_root")
            }
            outPoint = .coinbase(merkleRoot: root, vout: try coinbase.decode(UInt32.self, forKey: .vout))
        } else if let deposit = try? container.nestedContainer(keyedBy: DepositKeys.self, forKey: .deposit) {
            let hex = try deposit.decode(String.self, forKey: .txid)
            guard let displayOrder = ThunderHex.decode(hex), displayOrder.count == 32 else {
                throw ThunderRPCError.malformedResponse("deposit txid")
            }
            // bitcoin::Txid display hex is reversed relative to the internal bytes Borsh writes.
            outPoint = .deposit(txid: displayOrder.reversed(), vout: try deposit.decode(UInt32.self, forKey: .vout))
        } else {
            throw ThunderRPCError.malformedResponse("unknown outpoint variant")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch outPoint {
        case let .regular(txid, vout):
            var nested = container.nestedContainer(keyedBy: RegularKeys.self, forKey: .regular)
            try nested.encode(ThunderHex.encode(txid), forKey: .txid)
            try nested.encode(vout, forKey: .vout)
        case let .coinbase(merkleRoot, vout):
            var nested = container.nestedContainer(keyedBy: CoinbaseKeys.self, forKey: .coinbase)
            try nested.encode(ThunderHex.encode(merkleRoot), forKey: .merkleRoot)
            try nested.encode(vout, forKey: .vout)
        case let .deposit(txid, vout):
            var nested = container.nestedContainer(keyedBy: DepositKeys.self, forKey: .deposit)
            try nested.encode(ThunderHex.encode(txid.reversed()), forKey: .txid)   // back to display order
            try nested.encode(vout, forKey: .vout)
        }
    }
}

// MARK: - Output / PointedOutput

/// `types::Content` over JSON: `{"Value": <sats>}` or
/// `{"Withdrawal":{"value_sats":…,"main_fee_sats":…,"main_address":"…"}}` (note the `_sats` renames).
///
/// A withdrawal is kept as the node reports it — we never build one (v2) and, since commit f585f25,
/// **spending a withdrawal output is rejected by consensus**, so these are unspendable and excluded
/// from both balance and coin selection. We deliberately do not convert one into a domain
/// `ThunderOutputContent`: that would need `main_address`'s scriptPubKey bytes to Borsh-encode, and we
/// have no reason to reconstruct something we can never spend.
enum ThunderRPCContent: Codable, Equatable {
    case value(sats: UInt64)
    case withdrawal(valueSats: UInt64, mainFeeSats: UInt64, mainAddress: String)

    private enum Tag: String, CodingKey { case value = "Value", withdrawal = "Withdrawal" }
    private enum WithdrawalKeys: String, CodingKey {
        case valueSats = "value_sats", mainFeeSats = "main_fee_sats", mainAddress = "main_address"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Tag.self)
        if let sats = try? container.decode(UInt64.self, forKey: .value) {
            self = .value(sats: sats)
        } else if let nested = try? container.nestedContainer(keyedBy: WithdrawalKeys.self, forKey: .withdrawal) {
            self = .withdrawal(valueSats: try nested.decode(UInt64.self, forKey: .valueSats),
                               mainFeeSats: try nested.decode(UInt64.self, forKey: .mainFeeSats),
                               mainAddress: try nested.decode(String.self, forKey: .mainAddress))
        } else {
            throw ThunderRPCError.malformedResponse("unknown output content")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case let .value(sats):
            try container.encode(sats, forKey: .value)
        case let .withdrawal(valueSats, mainFeeSats, mainAddress):
            var nested = container.nestedContainer(keyedBy: WithdrawalKeys.self, forKey: .withdrawal)
            try nested.encode(valueSats, forKey: .valueSats)
            try nested.encode(mainFeeSats, forKey: .mainFeeSats)
            try nested.encode(mainAddress, forKey: .mainAddress)
        }
    }

    /// The domain content, or nil for an unspendable withdrawal (see the type's note).
    var domain: ThunderOutputContent? {
        switch self {
        case let .value(sats): return .value(sats: sats)
        case .withdrawal: return nil
        }
    }

    var valueSats: UInt64 {
        switch self {
        case let .value(sats): return sats
        case let .withdrawal(valueSats, mainFeeSats, _): return valueSats &+ mainFeeSats
        }
    }
}

/// `types::Output` over JSON: `{"address":"<base58>","content":…}`.
struct ThunderRPCOutput: Codable, Equatable {
    let address: String          // base58, per `Address`'s human-readable Serialize
    let content: ThunderRPCContent

    init(address: String, content: ThunderRPCContent) {
        self.address = address
        self.content = content
    }

    init(_ output: ThunderOutput) {
        self.address = ThunderAddress(bytes: output.address).base58
        switch output.content {
        case let .value(sats):
            self.content = .value(sats: sats)
        case let .withdrawal(sats, mainFeeSats, _):
            // Never produced by us — the send path only builds `.value` outputs.
            self.content = .withdrawal(valueSats: sats, mainFeeSats: mainFeeSats, mainAddress: "")
        }
    }
}

/// `types::PointedOutput` over JSON — what `get_utxos` returns for each UTXO.
struct ThunderRPCPointedOutput: Codable, Equatable {
    let outpoint: ThunderRPCOutPoint
    let output: ThunderRPCOutput

    /// The spendable domain UTXO, or nil if this output can't be spent (a withdrawal output, or an
    /// address we can't parse). Filtering here keeps unspendable coins out of balance and selection.
    var spendable: ThunderPointedOutput? {
        guard let content = output.content.domain,
              let address = ThunderAddress(base58: output.address) else { return nil }
        return ThunderPointedOutput(outPoint: outpoint.outPoint,
                                    output: ThunderOutput(address: address.bytes, content: content))
    }
}

// MARK: - SpentOutput (get_stxos)

/// `types::InPoint` over JSON — which transaction *spent* one of our outputs.
/// `{"Regular":{"txid":"<hex>","vin":0}}` or `{"Withdrawal":{"m6id":"<hex>"}}`.
///
/// The `Regular` case is what history is built from: its txid is the transaction that took the coin.
/// `Withdrawal` means the coin left via a BIP300 withdrawal bundle rather than an ordinary spend —
/// there's no Thunder txid to attribute it to, so history records it separately.
enum ThunderRPCInPoint: Codable, Equatable {
    case regular(txid: [UInt8], vin: UInt32)
    case withdrawal(m6idHex: String)

    private enum Tag: String, CodingKey { case regular = "Regular", withdrawal = "Withdrawal" }
    private enum RegularKeys: String, CodingKey { case txid, vin }
    private enum WithdrawalKeys: String, CodingKey { case m6id }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Tag.self)
        if let nested = try? container.nestedContainer(keyedBy: RegularKeys.self, forKey: .regular) {
            let hex = try nested.decode(String.self, forKey: .txid)
            guard let txid = ThunderHex.decode(hex), txid.count == 32 else {
                throw ThunderRPCError.malformedResponse("inpoint txid")
            }
            self = .regular(txid: txid, vin: try nested.decode(UInt32.self, forKey: .vin))
        } else if let nested = try? container.nestedContainer(keyedBy: WithdrawalKeys.self, forKey: .withdrawal) {
            self = .withdrawal(m6idHex: try nested.decode(String.self, forKey: .m6id))
        } else {
            throw ThunderRPCError.malformedResponse("unknown inpoint variant")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case let .regular(txid, vin):
            var nested = container.nestedContainer(keyedBy: RegularKeys.self, forKey: .regular)
            try nested.encode(ThunderHex.encode(txid), forKey: .txid)
            try nested.encode(vin, forKey: .vin)
        case let .withdrawal(m6idHex):
            var nested = container.nestedContainer(keyedBy: WithdrawalKeys.self, forKey: .withdrawal)
            try nested.encode(m6idHex, forKey: .m6id)
        }
    }
}

/// `types::SpentOutput` — the output as it was, plus where it went.
struct ThunderRPCSpentOutput: Codable, Equatable {
    let output: ThunderRPCOutput
    let inpoint: ThunderRPCInPoint
}

/// `Pointed<SpentOutput>` from `get_stxos`. Note the nesting: `Pointed`'s field is named `output`
/// whatever it holds, so a spent entry is `{"outpoint":…, "output":{"output":…, "inpoint":…}}`.
struct ThunderRPCPointedSpentOutput: Codable, Equatable {
    let outpoint: ThunderRPCOutPoint
    let output: ThunderRPCSpentOutput
}

// MARK: - Transaction (request side)

/// `Authorized<Transaction>` as `submit_transaction` wants it. Encode-only: this is the one value we
/// send, and we build it ourselves, so there is nothing to decode.
///
/// ```json
/// {"transaction":{"inputs":[[{"Regular":{…}},[32 numbers]]],
///                 "proof":{"targets":[],"hashes":[]},
///                 "outputs":[{"address":"…","content":{"Value":123}}]},
///  "authorizations":[{"verifying_key":[32 numbers],"signature":[64 numbers]}]}
/// ```
/// The **empty proof** is deliberate and required: `proof` has no `#[serde(default)]`, so the field
/// must be present, and `submit_transaction` overwrites it via `State::regenerate_proof` before
/// validating (thunder-rust commit fb922ee). It is `#[borsh(skip)]`, so it never enters the signed
/// bytes either way — which is the whole reason the phone can sign without the accumulator.
struct ThunderRPCAuthorizedTransaction: Encodable {
    let authorized: AuthorizedThunderTransaction

    private enum Keys: String, CodingKey { case transaction, authorizations }
    private enum TxKeys: String, CodingKey { case inputs, proof, outputs }
    private enum ProofKeys: String, CodingKey { case targets, hashes }
    private enum AuthKeys: String, CodingKey { case verifyingKey = "verifying_key", signature }

    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: Keys.self)

        var tx = root.nestedContainer(keyedBy: TxKeys.self, forKey: .transaction)
        // inputs: Vec<(OutPoint, Hash)> — a Rust tuple is a JSON array, and `Hash` = [u8; 32] has no
        // hex wrapper, so it goes out as 32 numbers (see this file's header note).
        var inputs = tx.nestedUnkeyedContainer(forKey: .inputs)
        for input in authorized.transaction.inputs {
            var pair = inputs.nestedUnkeyedContainer()
            try pair.encode(ThunderRPCOutPoint(input.outPoint))
            try pair.encode(input.utxoHash)
        }
        var proof = tx.nestedContainer(keyedBy: ProofKeys.self, forKey: .proof)
        try proof.encode([UInt64](), forKey: .targets)
        try proof.encode([String](), forKey: .hashes)
        try tx.encode(authorized.transaction.outputs.map(ThunderRPCOutput.init), forKey: .outputs)

        var authorizations = root.nestedUnkeyedContainer(forKey: .authorizations)
        for authorization in authorized.authorizations {
            var entry = authorizations.nestedContainer(keyedBy: AuthKeys.self)
            try entry.encode(authorization.verifyingKey, forKey: .verifyingKey)   // 32 numbers
            try entry.encode(authorization.signature, forKey: .signature)         // 64 numbers
        }
    }
}
