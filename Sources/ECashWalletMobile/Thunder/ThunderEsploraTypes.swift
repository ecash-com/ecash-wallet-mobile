// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// JSON shapes served by **drivechain-esplora** (github.com/octobocto/drivechain-esplora) — an
/// Esplora-compatible index in front of a rust sidechain node. Field names and route shapes come from
/// Blockstream's Esplora; the differences below all come from the chain, not from the index taking a
/// shortcut, and each one is load-bearing for us:
///
///   * **Hashes are not reversed.** A sidechain txid is a BLAKE3 digest the node renders in plain byte
///     order, and the index keeps that order. A *mainchain* txid inside a deposit stays in Bitcoin's
///     reversed display order — the same split `ThunderRPCOutPoint` already handles, and the same trap:
///     get it backwards and you build an input whose utreexo leaf hash is wrong.
///   * **There is no script.** `scriptpubkey` carries the 20-byte ed25519 address as hex,
///     `scriptpubkey_type` reads `sidechain_address`, and `scriptpubkey_address` is the base58 form.
///   * **`version`, `locktime` and `sequence` are always 0** — these chains have no such fields. The
///     index carries them so a stock Esplora parser doesn't break; we simply don't model them.
///   * **There is no mempool.** `/address/{a}/txs/mempool` is always `[]`. Everything the index reports
///     is confirmed, which is why `status.block_height` can be trusted when `confirmed` is true.
///
/// Decode-only: the one thing we ever send is a transaction, and that goes out through
/// `ThunderRPCAuthorizedTransaction` (`POST /tx` relays the body into `submit_transaction` unchanged,
/// so the request shape is identical to the node RPC's — see `ThunderEsploraClient.broadcast`).

// MARK: - Status

/// Where a transaction or output sits in the chain (`Status` in the index).
///
/// `blockHeight`/`blockTime` are optional in the wire shape but present in practice: the index only
/// serves connected blocks. They're modelled as optional anyway so a row without them degrades to
/// "confirmed, depth unknown" rather than failing the whole decode.
struct ThunderEsploraStatus: Decodable, Equatable {
    let confirmed: Bool
    let blockHeight: Int64?
    let blockHash: String?
    /// The mainchain block time of the block this sidechain block points at, in epoch seconds.
    /// A sidechain header carries no timestamp of its own.
    let blockTime: Int64?

    private enum Keys: String, CodingKey {
        case confirmed
        case blockHeight = "block_height"
        case blockHash = "block_hash"
        case blockTime = "block_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        blockHeight = try c.decodeIfPresent(Int64.self, forKey: .blockHeight)
        blockHash = try c.decodeIfPresent(String.self, forKey: .blockHash)
        blockTime = try c.decodeIfPresent(Int64.self, forKey: .blockTime)
    }

    init(confirmed: Bool, blockHeight: Int64?, blockHash: String?, blockTime: Int64?) {
        self.confirmed = confirmed
        self.blockHeight = blockHeight
        self.blockHash = blockHash
        self.blockTime = blockTime
    }

    /// Depth at a given chain tip: 1 for a tx in the tip block, 0 when unconfirmed or when the index
    /// is somehow ahead of the tip we read (two requests, so they can disagree by a block).
    func confirmations(tipHeight: Int64) -> Int32 {
        guard confirmed, let height = blockHeight, height <= tipHeight else { return 0 }
        return Int32(clamping: tipHeight - height + 1)
    }
}

// MARK: - Outpoint kind / content type

/// How an output came into being (`outpoint_kind`). Bitcoin has no such distinction; here it decides
/// which `ThunderOutPoint` variant — and therefore which Borsh tag — the outpoint encodes as.
enum ThunderEsploraOutpointKind: String, Equatable {
    case regular
    case coinbase
    case deposit

    /// Skip-safe parse (an explicit switch rather than `init(rawValue:)` — see `WalletBackend.Kind.from`).
    static func from(_ raw: String) -> ThunderEsploraOutpointKind? {
        switch raw {
        case "regular": return .regular
        case "coinbase": return .coinbase
        case "deposit": return .deposit
        default: return nil
        }
    }
}

/// What payload an output carries (`content_type`). Only `value` is a plain, spendable coin; a
/// `withdrawal` is refused by consensus on spend, so it must never reach balance or coin selection.
enum ThunderEsploraContentType {
    static let value = "value"
    static let withdrawal = "withdrawal"
}

// MARK: - UTXO

/// One unspent output, from `/address/{a}/utxo`.
///
/// Note what is **not** here: the address. The index keys the row by the address you asked for, so the
/// caller supplies it (`pointedOutput(address:)`). That's not a gap — it's why the per-address route
/// is usable at all for signing, since the address is the key we must resolve to sign the input.
struct ThunderEsploraUTXO: Decodable, Equatable {
    /// The outpoint's source hash: a Thunder txid (`regular`), a block merkle root (`coinbase`), or a
    /// **mainchain** txid in Bitcoin display order (`deposit`).
    let txid: String
    let vout: UInt32
    let value: Int64
    let status: ThunderEsploraStatus
    let outpointKind: String
    /// False for a deposit the node could not attribute to a block; the row then carries the height
    /// where the index first saw it. Surfaced so history can avoid presenting a guess as exact.
    let heightExact: Bool
    let contentType: String

    private enum Keys: String, CodingKey {
        case txid, vout, value, status
        case outpointKind = "outpoint_kind"
        case heightExact = "height_exact"
        case contentType = "content_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        txid = try c.decode(String.self, forKey: .txid)
        vout = try c.decode(UInt32.self, forKey: .vout)
        value = try c.decode(Int64.self, forKey: .value)
        status = try c.decode(ThunderEsploraStatus.self, forKey: .status)
        outpointKind = try c.decodeIfPresent(String.self, forKey: .outpointKind) ?? "regular"
        heightExact = try c.decodeIfPresent(Bool.self, forKey: .heightExact) ?? true
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? ThunderEsploraContentType.value
    }

    /// The spendable domain UTXO controlled by `address`, or nil when this output can't be spent.
    ///
    /// **This is the consensus-critical mapping in the whole Esplora path.** Every input carries
    /// `BLAKE3(borsh(PointedOutput))` as its utreexo leaf, and `PointedOutput` is the outpoint plus the
    /// full output — 20-byte address *and* content. So both halves must be reconstructed exactly:
    ///   * the address comes from the route we queried (hence the parameter), and
    ///   * the content is `Value(value)` — exact **only** for `content_type == "value"`.
    ///
    /// For a withdrawal the index reports `value` as payout **+** mainchain fee folded together, which
    /// would not round-trip to the node's `Content`. We return nil for those, so the filter that used
    /// to be merely cosmetic ("consensus rejects spending a withdrawal") is now also what stops us
    /// computing a wrong leaf hash. A negative or unparseable row is dropped for the same reason.
    func pointedOutput(address: ThunderAddress) -> ThunderPointedOutput? {
        guard contentType == ThunderEsploraContentType.value, value >= 0,
              let outPoint = outPoint() else { return nil }
        return ThunderPointedOutput(outPoint: outPoint,
                                    output: ThunderOutput(address: address.bytes,
                                                          content: .value(sats: UInt64(value))))
    }

    /// The domain outpoint, with the deposit byte-order flip applied.
    func outPoint() -> ThunderOutPoint? {
        guard let kind = ThunderEsploraOutpointKind.from(outpointKind),
              let hash = ThunderHex.decode(txid), hash.count == 32 else { return nil }
        switch kind {
        case .regular: return .regular(txid: hash, vout: vout)
        case .coinbase: return .coinbase(merkleRoot: hash, vout: vout)
        // A deposit names a MAINCHAIN txid, which the index renders in Bitcoin's reversed display
        // order. Borsh wants the internal bytes, so flip it here — the one place order changes.
        case .deposit: return .deposit(txid: hash.reversed(), vout: vout)
        }
    }
}

// MARK: - Transaction

/// One output of a transaction (`Vout`).
struct ThunderEsploraVout: Decodable, Equatable {
    /// Base58 form of the 20-byte address. Empty only if the index couldn't render one.
    let scriptPubKeyAddress: String
    let value: Int64
    let contentType: String

    private enum Keys: String, CodingKey {
        case scriptPubKeyAddress = "scriptpubkey_address"
        case value
        case contentType = "content_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        scriptPubKeyAddress = try c.decodeIfPresent(String.self, forKey: .scriptPubKeyAddress) ?? ""
        value = try c.decodeIfPresent(Int64.self, forKey: .value) ?? 0
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? ThunderEsploraContentType.value
    }

    init(scriptPubKeyAddress: String, value: Int64, contentType: String = ThunderEsploraContentType.value) {
        self.scriptPubKeyAddress = scriptPubKeyAddress
        self.value = value
        self.contentType = contentType
    }
}

/// One input of a transaction (`Vin`). The index always populates `prevout` — it says so explicitly,
/// because a stock Esplora client dereferences it without a nil check — but it's modelled optional so
/// a missing one costs us that input's value rather than the whole transaction.
struct ThunderEsploraVin: Decodable, Equatable {
    let prevout: ThunderEsploraVout?
    let isCoinbase: Bool

    private enum Keys: String, CodingKey {
        case prevout
        case isCoinbase = "is_coinbase"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        prevout = try c.decodeIfPresent(ThunderEsploraVout.self, forKey: .prevout)
        isCoinbase = try c.decodeIfPresent(Bool.self, forKey: .isCoinbase) ?? false
    }

    init(prevout: ThunderEsploraVout?, isCoinbase: Bool = false) {
        self.prevout = prevout
        self.isCoinbase = isCoinbase
    }
}

/// A transaction, from `/tx/{txid}` or a page of `/address/{a}/txs/chain`.
///
/// This is the shape that closes every gap `ThunderHistory` documents as underivable from the node
/// RPC: a real `fee`, a real height and time via `status`, and both sides of the ledger via
/// `vin[].prevout` — no reconstruction from unspent-vs-spent evidence, and no invented ordering.
struct ThunderEsploraTx: Decodable, Equatable {
    let txid: String
    let fee: Int64
    /// Canonical Borsh size in bytes. The index reports `weight` as exactly `size * 4`, so there is no
    /// separate vsize to derive — this IS the size a fee rate should divide by.
    let size: Int64
    let vin: [ThunderEsploraVin]
    let vout: [ThunderEsploraVout]
    let status: ThunderEsploraStatus

    private enum Keys: String, CodingKey { case txid, fee, size, vin, vout, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        txid = try c.decode(String.self, forKey: .txid)
        fee = try c.decodeIfPresent(Int64.self, forKey: .fee) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        vin = try c.decodeIfPresent([ThunderEsploraVin].self, forKey: .vin) ?? []
        vout = try c.decodeIfPresent([ThunderEsploraVout].self, forKey: .vout) ?? []
        status = try c.decode(ThunderEsploraStatus.self, forKey: .status)
    }

    init(txid: String, fee: Int64, size: Int64,
         vin: [ThunderEsploraVin], vout: [ThunderEsploraVout], status: ThunderEsploraStatus) {
        self.txid = txid
        self.fee = fee
        self.size = size
        self.vin = vin
        self.vout = vout
        self.status = status
    }
}

// MARK: - Address stats

/// Counts of what an address funded and spent (`TxoStats`).
struct ThunderEsploraTxoStats: Decodable, Equatable {
    let fundedTxoCount: Int
    let spentTxoCount: Int
    let txCount: Int

    private enum Keys: String, CodingKey {
        case fundedTxoCount = "funded_txo_count"
        case spentTxoCount = "spent_txo_count"
        case txCount = "tx_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        fundedTxoCount = try c.decodeIfPresent(Int.self, forKey: .fundedTxoCount) ?? 0
        spentTxoCount = try c.decodeIfPresent(Int.self, forKey: .spentTxoCount) ?? 0
        txCount = try c.decodeIfPresent(Int.self, forKey: .txCount) ?? 0
    }

    init(fundedTxoCount: Int, spentTxoCount: Int, txCount: Int) {
        self.fundedTxoCount = fundedTxoCount
        self.spentTxoCount = spentTxoCount
        self.txCount = txCount
    }
}

/// `/address/{a}` — the cheap "has this address ever been used?" probe.
///
/// This route is what makes a per-address index affordable on a phone. The window is 20+ addresses and
/// most are empty; asking for stats first (a handful of integers) and only fetching utxos/history for
/// the ones with `tx_count > 0` turns ~40 round trips into ~20 small ones plus a few real ones.
/// `mempool_stats` is always zero here — these nodes serve no mempool view — so only chain stats are
/// modelled.
struct ThunderEsploraAddressInfo: Decodable, Equatable {
    let chainStats: ThunderEsploraTxoStats

    private enum Keys: String, CodingKey { case chainStats = "chain_stats" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        chainStats = try c.decode(ThunderEsploraTxoStats.self, forKey: .chainStats)
    }

    init(chainStats: ThunderEsploraTxoStats) { self.chainStats = chainStats }

    /// Whether this address has ever appeared on-chain — the gap-limit signal.
    var isUsed: Bool { chainStats.txCount > 0 || chainStats.fundedTxoCount > 0 }
}
