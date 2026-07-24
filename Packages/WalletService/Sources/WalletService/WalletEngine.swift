// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later
//
// THE BDK SEAM. This is the only file in the codebase that imports
// BDK, and the only place with a platform `#if`. Because this module is Skip Lite
// (transpiled), the Android branch imports the Kotlin bdk-android API directly and
// type-checked; the iOS branch imports the bdk-swift binary. Keep every method body's
// two branches as thin as possible — both bindings come from the same Rust core.

import Foundation

// The BDK seam has THREE compile passes in this mixed Fuse-app + transpiled-WalletService
// project. There is no single platform where all three see BDK, so we gate on TWO symbols:
//
// Pass os(Android) SKIP SKIP_BRIDGE BDK available as
// ─────────────────────────────── ─────────── ───── ─────────── ──────────────────
// Apple native (swiftc) false false false BitcoinDevKit (bdk-swift)
// Android transpile (Skip→Kotlin) —            true false org.bitcoindevkit (bdk-android)
// Android native bridge true false TRUE NOTHING — bdk-swift is
// Apple-only, bdk-android is
// Kotlin; native Android Swift
// has neither.
//
// The bridge pass exists only to generate JNI bridges for the Fuse app from this module's PUBLIC
// API. That API surface (the `WalletEngineProtocol` + our value types) is BDK-free, so the bridge
// never needs BDK. We therefore exclude ALL BDK-touching code from the bridge pass with
// `#if !SKIP_BRIDGE` (per the skip-fuse SKIP_BRIDGE guidance), and inside it pick the binding by
// platform. On real Android, execution runs the TRANSPILED Kotlin — not this native Swift — so the
// guarded-out code is never missing at runtime.
#if !SKIP_BRIDGE
#if !os(Android)
import BitcoinDevKit // bdk-swift (Apple)
#elseif SKIP
import org.bitcoindevkit.__ // bdk-android (Kotlin) — note the `.__` wildcard
#endif
// The `#if !SKIP_BRIDGE` opened above stays OPEN through the protocol + class to EOF: with
// `bridging: true` the whole module is excluded from the bridge compile (Skip generates forwarders).
// Binding divergences (enum spelling, ChainPosition sealed class, etc.) are absorbed in `BDKSeam`
// (the one `#if SKIP`-split spot) + thin inline splits below. Non-colliding BDK types (Address,
// Transaction, Psbt, Script, TxBuilder, ElectrumClient, Wallet, Persister) are used unqualified;
// only `Amount`/`FeeRate` collide with our domain types, so BDK's are built via #if-inlined locals
// at the one call site that needs them (`send`).

/// The behaviour view models depend on — never the concrete engine. This is what makes
/// a `MockWalletEngine` possible for fast unit tests that never cross the BDK seam
/// One `WalletEngine` instance backs one `ManagedWallet`.
///
/// `public` so sibling files' transpiled Kotlin can resolve it; `// SKIP @nobridge` keeps it off
/// the JNI bridge (the app only ever touches it through `WalletManager` facade methods).
// SKIP @nobridge
public protocol WalletEngineProtocol: AnyObject {
    var network: WalletNetwork { get }

    /// SPENDABLE ("Available") balance: confirmed coins + our own unconfirmed change.
    func balance() throws -> Amount
    /// NOT-yet-spendable balance: incoming unconfirmed (0-conf) + immature coinbase. Shown
    /// separately so funds aren't perceived as lost while they wait to confirm.
    func pendingBalance() throws -> Amount
    func nextReceiveAddress() throws -> AddressInfo
    /// The lowest revealed-but-unused receive address (reveals one only if none exists). Does
    /// NOT advance on repeat calls — the default for the Receive screen, so casual opens don't
    /// burn through the index space (every revealed index widens what sync must check).
    func nextUnusedAddress() throws -> AddressInfo
    func transactions() throws -> [WalletTx]
    func listUtxos() throws -> [Utxo]

    /// Build → sign → broadcast happens inside; returns the broadcast tx.
    func send(to address: String, amount: Amount, feeRate: FeeRate) throws -> WalletTx

    /// Sweep the entire spendable balance to `address` (true drain — all UTXOs, no change, exact fee
    /// deducted). The correct "Max" and the coin-splitting primitive. Build → sign → broadcast inside.
    func sweep(to address: String, feeRate: FeeRate) throws -> WalletTx

    /// Split coins: drain the whole spendable balance to a FRESH address of THIS wallet (destination
    /// wallet-owned by construction — no external address). Separates fork-airdrop coins.
    func splitToSelf(feeRate: FeeRate) throws -> WalletTx

    /// Read-only split status (total spendable vs pre-fork amount needing a split). No I/O beyond the
    /// local UTXO set; drives the split nudge + the amount shown in the flow.
    func splitSummary() throws -> SplitSummary

    /// Publish an `OP_RETURN` data output (e.g. a CoinNews message). Funds the fee from the wallet's
    /// spendable coins, adds change, signs, and broadcasts. Returns the optimistic pending tx.
    func publishData(_ data: Data, feeRate: FeeRate) throws -> WalletTx

    /// Sync against the wallet's network backend. Off the main actor.
    func sync() async throws
}

/// The real engine, wrapping one BDK `Wallet` + its `Persister`. Built by
/// `BDKWalletEngineFactory.engine(for:mnemonic:)`. BDK reads are mapped to our bridge-safe
/// value types (`Amount`, `AddressInfo`, …) — our types win the unqualified name over BDK's
/// same-named types because they're declared in this module.
///
/// Excluded from the bridge pass (`#if !SKIP_BRIDGE`): it stores BDK-typed properties and the app
/// only ever sees it as `WalletEngineProtocol`, so the JNI bridge never needs the concrete type.
/// On real Android this runs as transpiled Kotlin against bdk-android.
///
/// `balance`/`nextReceiveAddress`/`transactions`/`listUtxos` are implemented + host-tested.
/// `sync`/`send` are implemented but await device verification against live L2L Signet / a funded
/// wallet (Golden Rule §8 — they fail loud, never silent).
///
/// `public` (cross-file Kotlin resolution) + `// SKIP @nobridge` (BDK-typed init/properties must
/// never reach the JNI bridge). Members stay `internal` so nothing BDK-typed is bridged.
// SKIP @nobridge
public final class WalletEngine: WalletEngineProtocol {
    public let network: WalletNetwork
    /// WATCH-ONLY wallet (built from public descriptors): balance, addresses, sync, PSBT building.
    /// It cannot sign — signing goes through `signPsbt` (sign-on-demand, §7).
    private let wallet: Wallet
    private let persister: Persister
    /// The Electrum backend URL for this wallet's network (resolved by the factory from
    /// `NetworkRegistry`, so the engine never hardcodes a network/endpoint — Golden Rule §4).
    private let backend: WalletBackend
    /// Signs a PSBT on demand by materializing the secret key transiently (factory-supplied).
    /// Returns whether the PSBT is finalized. The only path that touches private key material.
    private let signPsbt: (Psbt) throws -> Bool

    /// Internal: only the factory (same module) builds this; the app sees `WalletEngineProtocol`.
    /// Kept non-public so the bridge never sees the BDK-typed parameters. (Can't be `public` anyway —
    /// its params use internal types like `WalletBackend`.)
    init(wallet: Wallet, persister: Persister, network: WalletNetwork, backend: WalletBackend,
         signPsbt: @escaping (Psbt) throws -> Bool) {
        self.wallet = wallet
        self.persister = persister
        self.network = network
        self.backend = backend
        self.signPsbt = signPsbt
    }

    /// SPENDABLE / "Available" balance — confirmed coins + our OWN unconfirmed change
    /// (BDK's `trustedPending`). Incoming unconfirmed (`untrustedPending`) and immature coinbase
    /// are deliberately excluded: they're reported by `pendingBalance()` and can't be spent until
    /// they confirm (spend policy — see README "Spendable balance"). This is what coin selection in
    /// `send` honors too, via `untrustedUnconfirmedOutpoints()`.
    public func balance() throws -> Amount {
        let balance = wallet.balance()
        // BDK vends UInt64 sats; our Amount is signed Int64 (bridge-safe, fits all real values).
        let available = balance.confirmed.toSat() + balance.trustedPending.toSat()
        return Amount(sats: Int64(available))
    }

    /// NOT-yet-spendable balance — incoming 0-conf (`untrustedPending`) + immature coinbase.
    /// Surfaced separately so received-but-unconfirmed funds read as "pending", not missing.
    public func pendingBalance() throws -> Amount {
        let balance = wallet.balance()
        let pending = balance.untrustedPending.toSat() + balance.immature.toSat()
        return Amount(sats: Int64(pending))
    }

    public func nextReceiveAddress() throws -> AddressInfo {
        let info = wallet.revealNextAddress(keychain: BDKSeam.externalKeychain())
        // Persist the advanced derivation index so an address is never handed out twice.
        _ = try wallet.persist(persister: persister)
        // String interpolation forces the address Display (`.toString()` on Kotlin) — portable.
        return AddressInfo(address: "\(info.address)", index: Int32(info.index))
    }

    public func nextUnusedAddress() throws -> AddressInfo {
        let info = wallet.nextUnusedAddress(keychain: BDKSeam.externalKeychain())
        // May have revealed (only when nothing unused existed) — persist like reveal does.
        _ = try wallet.persist(persister: persister)
        return AddressInfo(address: "\(info.address)", index: Int32(info.index))
    }

    public func transactions() throws -> [WalletTx] {
        let tipHeight = wallet.latestCheckpoint().height
        // Build into a Swift array (not `.map`): a `.map` over the Kotlin `List` bdk-android
        // returns produces a Kotlin `List`, which mismatches our `[WalletTx]` (Skip `Array`).
        var result: [WalletTx] = []
        for canonical in wallet.transactions() {
            let tx = canonical.transaction
            let flow = wallet.sentAndReceived(tx: tx)
            // net = received − sent, as a signed Int64 (positive = inbound to this wallet).
            let netSats = Int64(flow.received.toSat()) - Int64(flow.sent.toSat())
            // Fee isn't computable for some txs (e.g. missing prevouts on a pure receive) — drop it.
            // Int64? (not BDK's UInt64) — bridged property surfaces are signed-only (see WalletTx).
            var feeSats: Int64? = nil
            if let bdkFee = (try? wallet.calculateFee(tx: tx))?.toSat() {
                feeSats = Int64(bdkFee)
            }

            // ChainPosition diverges: Swift enum with associated values vs Kotlin sealed class.
            let confirmations: Int32
            let timestamp: Int64?
            let blockHeight: Int64?
            #if SKIP
            if let confirmed = canonical.chainPosition as? ChainPosition.Confirmed {
                let confHeight = confirmed.confirmationBlockTime.blockId.height
                confirmations = tipHeight >= confHeight ? Int32(tipHeight - confHeight + UInt32(1)) : 0
                timestamp = Int64(confirmed.confirmationBlockTime.confirmationTime)
                blockHeight = Int64(confHeight)
            } else {
                confirmations = 0
                timestamp = nil
                blockHeight = nil
            }
            #else
            switch canonical.chainPosition {
            case .confirmed(let confirmationBlockTime, _):
                let confHeight = confirmationBlockTime.blockId.height
                confirmations = tipHeight >= confHeight ? Int32(tipHeight - confHeight + UInt32(1)) : 0
                timestamp = Int64(confirmationBlockTime.confirmationTime)
                blockHeight = Int64(confHeight)
            case .unconfirmed:
                confirmations = 0
                timestamp = nil
                blockHeight = nil
            }
            #endif

            result.append(WalletTx(txid: "\(tx.computeTxid())",
                                   netSats: netSats,
                                   feeSats: feeSats,
                                   confirmations: confirmations,
                                   timestampEpochSeconds: timestamp,
                                   isRBF: tx.isExplicitlyRbf(),
                                   blockHeight: blockHeight,
                                   vsize: Int64(tx.vsize()),
                                   coinNewsKind: coinNewsKind(of: tx)))
        }
        return result
    }

    // MARK: - CoinNews OP_RETURN detection
    //
    // BDK hands us the full transaction, so we can scan its outputs for a CoinNews `OP_RETURN`
    // (`OP_RETURN ‖ push("CN" ‖ typeTag ‖ …)`) and label the tx for the Activity list. Pure byte
    // inspection — no decode of the message body.

    /// The CoinNews kind for a transaction, by scanning its outputs for a CoinNews OP_RETURN.
    private func coinNewsKind(of tx: Transaction) -> String? {
        for out in tx.output() {
            // `Script.toBytes()` → `Data` (bdk-swift) / `ByteArray` (bdk-android, wrap with
            // `Data(platformValue:)`, same as `addData`).
            #if SKIP
            let script = Data(platformValue: out.scriptPubkey.toBytes())
            #else
            let script = out.scriptPubkey.toBytes()
            #endif
            if let kind = WalletEngine.coinNewsKind(fromScript: script) { return kind }
        }
        return nil
    }

    /// CoinNews kind from an OP_RETURN output script, or nil if it isn't a CoinNews OP_RETURN.
    /// Script shape: `0x6a` (OP_RETURN) then one data push (direct length `0x01..0x4b`, or
    /// `OP_PUSHDATA1 = 0x4c` followed by a length byte), whose payload starts with `"CN"` + tag.
    static func coinNewsKind(fromScript script: Data) -> String? {
        guard script.count >= 2, script[0] == UInt8(0x6a) else { return nil }
        var i = 1
        let op = script[i]
        i += 1
        var dataLen = 0
        if op >= UInt8(0x01) && op <= UInt8(0x4b) {
            dataLen = Int(op)
        } else if op == UInt8(0x4c) && i < script.count {
            dataLen = Int(script[i])
            i += 1
        } else {
            return nil
        }
        // Need "CN"(2) + tag(1) at the start of the pushed payload.
        guard dataLen >= 3, i + dataLen <= script.count else { return nil }
        guard script[i] == UInt8(0x43), script[i + 1] == UInt8(0x4e) else { return nil }
        return coinNewsKind(forTag: script[i + 2])
    }

    /// CoinNews kind from a raw payload (the bytes we hand to `addData`: `"CN" ‖ tag ‖ …`).
    static func coinNewsKind(fromPayload payload: Data) -> String? {
        guard payload.count >= 3, payload[0] == UInt8(0x43), payload[1] == UInt8(0x4e) else { return nil }
        return coinNewsKind(forTag: payload[2])
    }

    /// Map a CoinNews type tag (§2) to a display kind.
    static func coinNewsKind(forTag tag: UInt8) -> String? {
        if tag == UInt8(0x01) { return "topic" }
        if tag == UInt8(0x02) { return "story" }
        if tag == UInt8(0x03) { return "comment" }
        if tag == UInt8(0x04) { return "upvote" }
        if tag == UInt8(0x05) { return "downvote" }
        if tag == UInt8(0x06) { return "continuation" }
        return nil
    }

    /// Outpoints to KEEP OUT of coin selection: unconfirmed UTXOs that aren't our own change.
    /// An unconfirmed tx is "trusted" only if we contributed inputs to it (`sentAndReceived.sent
    /// > 0` → our own spend/change); incoming 0-conf (no inputs of ours) is "untrusted" and stays
    /// unspendable until it confirms — so a sender can't get us to forward coins that could be
    /// double-spent or RBF-replaced before confirming. Mirrors Bitcoin Core's trusted/untrusted
    /// rule. (Spend policy — README "Spendable balance".)
    private func untrustedUnconfirmedOutpoints() -> [OutPoint] {
        var unconfirmedTxids = Set<String>()
        var trustedTxids = Set<String>()
        for canonical in wallet.transactions() {
            let tx = canonical.transaction
            let confirmed: Bool
            #if SKIP
            confirmed = canonical.chainPosition is ChainPosition.Confirmed
            #else
            switch canonical.chainPosition {
            case .confirmed: confirmed = true
            case .unconfirmed: confirmed = false
            }
            #endif
            if confirmed { continue }
            let txid = "\(tx.computeTxid())"
            unconfirmedTxids.insert(txid)
            if wallet.sentAndReceived(tx: tx).sent.toSat() > UInt64(0) {
                trustedTxids.insert(txid)   // our own unconfirmed change → spendable
            }
        }
        var excluded: [OutPoint] = []
        for output in wallet.listUnspent() {
            let txid = "\(output.outpoint.txid)"
            if unconfirmedTxids.contains(txid) && !trustedTxids.contains(txid) {
                excluded.append(output.outpoint)
            }
        }
        return excluded
    }

    public func listUtxos() throws -> [Utxo] {
        // listUnspent() already excludes spent outputs. Build into a Swift array (see transactions()).
        var result: [Utxo] = []
        for output in wallet.listUnspent() {
            result.append(Utxo(txid: "\(output.outpoint.txid)",
                               vout: Int32(output.outpoint.vout),
                               amount: Amount(sats: Int64(output.txout.value.toSat()))))
        }
        return result
    }

    /// Stamp the network's replay-protection `nLockTime` on a tx builder, if it has one. For eCash
    /// this sets `nLockTime = 499_999_999` (LOCKTIME_THRESHOLD - 1) — final on eCash, a far-future
    /// block-height lock on Bitcoin → the tx can't replay onto BTC (NetworkRegistry
    /// `replayProtectionLockHeight`). No-op on Bitcoin/Signet. The protection also needs a non-final
    /// input sequence, which BDK's default RBF (`0xFFFFFFFD`) provides — do NOT disable RBF on eCash.
    private func applyingReplayProtection(_ builder: TxBuilder) -> TxBuilder {
        guard let height = NetworkRegistry.replayProtectionLockHeight(for: network) else { return builder }
        #if SKIP
        let lock = LockTime.Blocks(height: height)   // bdk-android (Kotlin sealed-class variant)
        #else
        let lock = LockTime.blocks(height: height)   // bdk-swift
        #endif
        return builder.nlocktime(locktime: lock)
    }

    /// Build → sign → broadcast. The flow is implemented end-to-end, but it has NOT been
    /// verified against a funded wallet on live L2L Signet — that requires device/emulator testing
    /// with real coins. TODO(M2-device): confirm fee/change/RBF on a real send.
    public func send(to address: String, amount: Amount, feeRate: FeeRate) throws -> WalletTx {
        // 1. Validate the destination address against THIS wallet's network (Golden Rule §6/§7).
        let bdkAddress: Address
        do {
            bdkAddress = try Address(address: address, network: BDKSeam.network(network))
        } catch {
            throw WalletError.invalidAddress
        }
        let script = bdkAddress.scriptPubkey()

        // 2. Build the PSBT. BDK does coin selection, change, and fee math (Golden Rule §1).
        // `Amount`/`FeeRate` collide with our domain types, so build BDK's via #if-inlined locals
        // (type inferred — no module-qualified typealias needed).
        // Our Amount is signed Int64; BDK's fromSat takes UInt64 (negative is impossible here —
        // an Amount is never constructed negative, and the conversion traps loudly if it were).
        #if SKIP
        let bdkAmount = org.bitcoindevkit.Amount.fromSat(satoshi: UInt64(amount.sats))
        #else
        let bdkAmount = BitcoinDevKit.Amount.fromSat(satoshi: UInt64(amount.sats))
        #endif
        let psbt: Psbt
        do {
            #if SKIP
            let bdkFeeRate = try org.bitcoindevkit.FeeRate.fromSatPerVb(satVb: UInt64(feeRate.satPerVByte))
            #else
            let bdkFeeRate = try BitcoinDevKit.FeeRate.fromSatPerVb(satVb: UInt64(feeRate.satPerVByte))
            #endif
            // Spend policy: confirmed coins + our own unconfirmed change only. Excluding the
            // untrusted (incoming 0-conf) outpoints keeps them out of coin selection (empty list
            // is a harmless no-op). See `untrustedUnconfirmedOutpoints` / README "Spendable balance".
            // bdk-android's `unspendable` takes a Kotlin `List`, so convert the Swift array to the
            // backing Kotlin list on the transpiled side; Apple takes the `[OutPoint]` as-is.
            let untrusted: [OutPoint] = untrustedUnconfirmedOutpoints()
            #if SKIP
            // `.kotlin()` yields a star-projected MutableList; the unchecked cast restores the
            // concrete element type bdk-android's `unspendable(List<OutPoint>)` requires (the list
            // really does hold OutPoints, so the cast is safe).
            let unspendable = untrusted.kotlin() as! kotlin.collections.List<OutPoint>
            #else
            let unspendable = untrusted
            #endif
            var builder = TxBuilder()
                .addRecipient(script: script, amount: bdkAmount)
                .feeRate(feeRate: bdkFeeRate)
                .unspendable(unspendable: unspendable)
            builder = applyingReplayProtection(builder)
            psbt = try builder.finish(wallet: wallet)
        } catch {
            // Insufficient-funds / dust / fee errors classified, never echoed (Golden Rule §2).
            throw WalletError.mapping(rawDescription: "\(error)")
        }

        // 3-5. Sign on demand → broadcast → fold into the wallet graph → return the optimistic tx.
        return try finalizeAndBroadcast(psbt)
    }

    /// Sweep the ENTIRE spendable balance to `address` — a true drain (all UTXOs, no change, the exact
    /// fee deducted from the swept amount) via BDK `drainWallet()` + `drainTo()`. This is the correct
    /// "Max" (balance-minus-estimate can under/over-shoot the fee → dust or insufficient-funds), and the
    /// primitive behind coin-splitting (sweep to a fresh address; replay-safe via the eCash nLockTime
    /// marker). Same spend policy, replay protection, and sign/broadcast path as `send`. Works for WIF
    /// single-key wallets too (drainWallet spends every UTXO regardless of descriptor type).
    public func sweep(to address: String, feeRate: FeeRate) throws -> WalletTx {
        let bdkAddress: Address
        do {
            bdkAddress = try Address(address: address, network: BDKSeam.network(network))
        } catch {
            throw WalletError.invalidAddress
        }
        return try finalizeAndBroadcast(try buildDrain(to: bdkAddress.scriptPubkey(), feeRate: feeRate))
    }

    /// **Split coins**: drain the wallet's entire spendable balance to a FRESH address of THIS wallet —
    /// separating a fork-airdrop holder's eCash from their Bitcoin (the swept coins land on a post-fork,
    /// replay-protected UTXO; the eCash `nLockTime` marker makes it un-replayable onto Bitcoin). The
    /// destination is derived from the wallet itself (`revealNextAddress`), so it is **wallet-owned by
    /// construction** — no app-supplied address, no chance of sending funds to the wrong place. On any
    /// failure nothing is broadcast (funds untouched). Same drain + replay + sign/broadcast path as sweep.
    public func splitToSelf(feeRate: FeeRate) throws -> WalletTx {
        let info = wallet.revealNextAddress(keychain: BDKSeam.externalKeychain())
        _ = try? wallet.persist(persister: persister)   // record the revealed index so future syncs track it
        return try finalizeAndBroadcast(try buildDrain(to: info.address.scriptPubkey(), feeRate: feeRate))
    }

    /// Build a drain PSBT to `script`: every spendable UTXO in, no change, exact fee out — plus the
    /// wallet's spend policy (excludes untrusted 0-conf) and eCash replay protection. Shared by
    /// `sweep`/`splitToSelf`. Throws a classified `WalletError` (insufficient funds, dust, …); never
    /// broadcasts.
    private func buildDrain(to script: Script, feeRate: FeeRate) throws -> Psbt {
        do {
            #if SKIP
            let bdkFeeRate = try org.bitcoindevkit.FeeRate.fromSatPerVb(satVb: UInt64(feeRate.satPerVByte))
            #else
            let bdkFeeRate = try BitcoinDevKit.FeeRate.fromSatPerVb(satVb: UInt64(feeRate.satPerVByte))
            #endif
            let untrusted: [OutPoint] = untrustedUnconfirmedOutpoints()
            #if SKIP
            let unspendable = untrusted.kotlin() as! kotlin.collections.List<OutPoint>
            #else
            let unspendable = untrusted
            #endif
            var builder = TxBuilder()
                .drainWallet()                 // spend every (spendable) UTXO
                .drainTo(script: script)       // all value minus the exact fee → one output, no change
                .feeRate(feeRate: bdkFeeRate)
                .unspendable(unspendable: unspendable)
            builder = applyingReplayProtection(builder)
            return try builder.finish(wallet: wallet)
        } catch {
            throw WalletError.mapping(rawDescription: "\(error)")
        }
    }

    /// Read-only split status: total spendable vs how much is pre-fork (needs splitting). Classifies
    /// each spendable UTXO by its confirmation height against `NetworkRegistry.forkHeight`. Excludes
    /// untrusted 0-conf (not drainable), matching what `splitToSelf` would actually move.
    public func splitSummary() throws -> SplitSummary {
        let fork = NetworkRegistry.forkHeight(for: network)
        var untrustedKeys = Set<String>()
        for op in untrustedUnconfirmedOutpoints() { untrustedKeys.insert("\(op.txid):\(op.vout)") }
        var spendable: [SplitUtxo] = []
        for out in wallet.listUnspent() {
            if untrustedKeys.contains("\(out.outpoint.txid):\(out.outpoint.vout)") { continue }
            spendable.append(SplitUtxo(height: confirmationHeight(of: out),
                                       sats: Int64(out.txout.value.toSat())))
        }
        return SplitSummary.classify(spendable, forkHeight: fork)
    }

    /// The confirmation block height of a UTXO, or nil if unconfirmed. ChainPosition diverges (Swift
    /// enum with associated values vs Kotlin sealed class) — same split as `transactions()`.
    private func confirmationHeight(of output: LocalOutput) -> Int64? {
        #if SKIP
        if let confirmed = output.chainPosition as? ChainPosition.Confirmed {
            return Int64(confirmed.confirmationBlockTime.blockId.height)
        }
        return nil
        #else
        switch output.chainPosition {
        case .confirmed(let confirmationBlockTime, _):
            return Int64(confirmationBlockTime.blockId.height)
        case .unconfirmed:
            return nil
        }
        #endif
    }

    /// The shared tail of `send`/`sweep`: sign the built PSBT on demand, broadcast it, fold it into the
    /// wallet graph, and return the optimistic `WalletTx`.
    private func finalizeAndBroadcast(_ psbt: Psbt) throws -> WalletTx {
        // Sign ON DEMAND. The watch-only wallet can't sign; `signPsbt` transiently materializes the
        // key, signs, and drops it (§7). A signing failure must never leak key/descriptor (§2/§8).
        do {
            let finalized = try signPsbt(psbt)
            guard finalized else { throw WalletError.signingFailed }
        } catch let e as WalletError {
            throw e
        } catch {
            throw WalletError.signingFailed
        }

        // Extract + broadcast over the wallet's backend.
        let tx: Transaction
        do {
            tx = try psbt.extractTx()
        } catch {
            throw WalletError.signingFailed
        }
        do {
            switch backend.kind {
            case .electrum:
                let client = try ElectrumClient(url: backend.url, socks5: backend.socks5)
                _ = try client.transactionBroadcast(tx: tx)
            case .esplora:
                let client = EsploraClient(url: backend.url, proxy: backend.socks5)
                try client.broadcast(transaction: tx)
            }
        } catch {
            // Known context: a broadcast/network failure. (The tx is signed/valid; this is transport.)
            throw WalletError.broadcastFailed
        }

        // Fold the broadcast tx into the wallet graph (spent inputs + new change) so a follow-up
        // send BEFORE the next sync doesn't reselect now-spent UTXOs and fail (the "second send
        // fails until pull-to-refresh" bug). Then persist and return the optimistic tx for the UI.
        applyBroadcast(tx)
        _ = try? wallet.persist(persister: persister)
        let flow = wallet.sentAndReceived(tx: tx)
        let netSats = Int64(flow.received.toSat()) - Int64(flow.sent.toSat())
        var feeSats: Int64? = nil
        if let bdkFee = (try? wallet.calculateFee(tx: tx))?.toSat() {
            feeSats = Int64(bdkFee)
        }
        return WalletTx(txid: "\(tx.computeTxid())",
                        netSats: netSats,
                        feeSats: feeSats,
                        confirmations: 0,
                        timestampEpochSeconds: nil,
                        isRBF: tx.isExplicitlyRbf(),
                        blockHeight: nil,
                        vsize: Int64(tx.vsize()))
    }

    /// Publish an `OP_RETURN` data output (CoinNews message). Same build → sign → broadcast path as
    /// `send`, but the only output is the value-0 `OP_RETURN` (`TxBuilder.addData`); BDK funds the
    /// fee from spendable coins and adds change. The data is one push — relay policy caps it at 80
    /// bytes on default nodes, but L2L networks raise `-datacarriersize` for CoinNews, so we don't
    /// hard-cap here; an over-limit payload simply fails at broadcast.
    public func publishData(_ data: Data, feeRate: FeeRate) throws -> WalletTx {
        let psbt: Psbt
        do {
            #if SKIP
            let bdkFeeRate = try org.bitcoindevkit.FeeRate.fromSatPerVb(satVb: UInt64(feeRate.satPerVByte))
            #else
            let bdkFeeRate = try BitcoinDevKit.FeeRate.fromSatPerVb(satVb: UInt64(feeRate.satPerVByte))
            #endif
            // Same spend policy as send: confirmed + own change only.
            let untrusted: [OutPoint] = untrustedUnconfirmedOutpoints()
            #if SKIP
            let unspendable = untrusted.kotlin() as! kotlin.collections.List<OutPoint>
            #else
            let unspendable = untrusted
            #endif
            // bdk-android's `addData` takes a Kotlin `ByteArray` (`Data.platformValue`); bdk-swift
            // takes `Data`.
            #if SKIP
            let withData = TxBuilder().addData(data: data.platformValue)
            #else
            let withData = TxBuilder().addData(data: data)
            #endif
            var builder = withData
                .feeRate(feeRate: bdkFeeRate)
                .unspendable(unspendable: unspendable)
            builder = applyingReplayProtection(builder)
            psbt = try builder.finish(wallet: wallet)
        } catch {
            throw WalletError.mapping(rawDescription: "\(error)")
        }

        // Sign on demand (watch-only build → transient key, §7).
        do {
            let finalized = try signPsbt(psbt)
            guard finalized else { throw WalletError.signingFailed }
        } catch let e as WalletError {
            throw e
        } catch {
            throw WalletError.signingFailed
        }

        let tx: Transaction
        do {
            tx = try psbt.extractTx()
        } catch {
            throw WalletError.signingFailed
        }
        do {
            switch backend.kind {
            case .electrum:
                let client = try ElectrumClient(url: backend.url, socks5: backend.socks5)
                _ = try client.transactionBroadcast(tx: tx)
            case .esplora:
                let client = EsploraClient(url: backend.url, proxy: backend.socks5)
                try client.broadcast(transaction: tx)
            }
        } catch {
            throw WalletError.broadcastFailed
        }

        // Fold the broadcast tx into the wallet graph (spent inputs + change) so a follow-up
        // send/publish before the next sync doesn't reselect now-spent UTXOs and fail.
        applyBroadcast(tx)
        _ = try? wallet.persist(persister: persister)
        let flow = wallet.sentAndReceived(tx: tx)
        let netSats = Int64(flow.received.toSat()) - Int64(flow.sent.toSat())
        var feeSats: Int64? = nil
        if let bdkFee = (try? wallet.calculateFee(tx: tx))?.toSat() {
            feeSats = Int64(bdkFee)
        }
        // We built this OP_RETURN ourselves — classify straight from the payload so the optimistic
        // Activity row is marked immediately (sync later re-derives it from the output script).
        return WalletTx(txid: "\(tx.computeTxid())",
                        netSats: netSats,
                        feeSats: feeSats,
                        confirmations: 0,
                        timestampEpochSeconds: nil,
                        isRBF: tx.isExplicitlyRbf(),
                        blockHeight: nil,
                        vsize: Int64(tx.vsize()),
                        coinNewsKind: WalletEngine.coinNewsKind(fromPayload: data))
    }

    /// After a successful broadcast, fold the tx into the wallet's local graph so its inputs are
    /// marked spent and its change becomes spendable IMMEDIATELY — no sync required. Without this a
    /// second send before the next sync reselects the just-spent UTXOs, producing a double-spend the
    /// backend rejects (the reported "next transaction fails unless you pull-to-refresh" bug).
    /// `lastSeen` = now (unix seconds); BDK uses it as the mempool last-seen for eviction ordering.
    /// `applyUnconfirmedTxs` is non-throwing (it can only no-op if the tx is already known).
    private func applyBroadcast(_ tx: Transaction) {
        let lastSeen = UInt64(Date().timeIntervalSince1970)
        let unconfirmed = [UnconfirmedTx(tx: tx, lastSeen: lastSeen)]
        #if SKIP
        // bdk-android wants a Kotlin `List<UnconfirmedTx>` (same as the `unspendable` conversion).
        wallet.applyUnconfirmedTxs(unconfirmedTxs: unconfirmed.kotlin() as! kotlin.collections.List<UnconfirmedTx>)
        #else
        wallet.applyUnconfirmedTxs(unconfirmedTxs: unconfirmed)
        #endif
    }

    /// Sync against the wallet's Electrum backend.
    ///
    /// First-ever sync (no checkpoint yet) = FULL SCAN: discovers used scripts with a gap limit
    /// of 20 consecutive unused. Every later sync = `startSyncWithRevealedSpks`: checks ALL
    /// revealed addresses regardless of gaps. The full scan's gap limit MISSES funds sent to a
    /// high revealed index (>20 unused below it) — exactly what happened when the Receive screen
    /// advanced the index on every open and an incoming tx landed at index ~34 (2026-06-12). The
    /// revealed-spk sync finds those, and is also cheaper for repeat refreshes.
    ///
    /// The BDK Electrum calls here are synchronous; callers must invoke `sync()` off the main
    /// actor. It's `async` so the call site can `await` it on a background task.
    public func sync() async throws {
        do {
            // Fresh wallet (genesis checkpoint only) → full scan (gap limit 20); else revealed-spks
            // sync (no gap-limit blind spots). Branch by backend type — the two BDK clients have
            // different scan/sync signatures (Electrum: batchSize+fetchPrevTxouts; Esplora:
            // parallelRequests). Both take an optional SOCKS5/proxy for Tor.
            let isFresh = wallet.latestCheckpoint().height == UInt32(0)
            switch backend.kind {
            case .electrum:
                let client = try ElectrumClient(url: backend.url, socks5: backend.socks5)
                if isFresh {
                    let request = try wallet.startFullScan().build()
                    let update = try client.fullScan(request: request, stopGap: UInt64(20),
                                                     batchSize: UInt64(10), fetchPrevTxouts: true)
                    try wallet.applyUpdate(update: update)
                } else {
                    let request = try wallet.startSyncWithRevealedSpks().build()
                    let update = try client.sync(request: request, batchSize: UInt64(10),
                                                 fetchPrevTxouts: true)
                    try wallet.applyUpdate(update: update)
                }
            case .esplora:
                let client = EsploraClient(url: backend.url, proxy: backend.socks5)
                if isFresh {
                    let request = try wallet.startFullScan().build()
                    let update = try client.fullScan(request: request, stopGap: UInt64(20),
                                                     parallelRequests: UInt64(4))
                    try wallet.applyUpdate(update: update)
                } else {
                    let request = try wallet.startSyncWithRevealedSpks().build()
                    let update = try client.sync(request: request, parallelRequests: UInt64(4))
                    try wallet.applyUpdate(update: update)
                }
            }
            _ = try wallet.persist(persister: persister)
        } catch {
            // Any failure here is a sync failure (network/server/connection) — the context is known,
            // so map directly rather than sniffing the (scrubbed) error text. User-actionable: retry.
            throw WalletError.syncFailed
        }
    }
}
#endif // !SKIP_BRIDGE
