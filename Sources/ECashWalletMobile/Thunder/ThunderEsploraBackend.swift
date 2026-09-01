// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import WalletService

/// The `ThunderBackend` backed by a **drivechain-esplora** index.
///
/// The index has no batch-address route — Blockstream's Esplora has none and this is faithful to it —
/// so the one real cost of this path is request count: a 21-address window is 21 requests, not the
/// node RPC's one. Two things keep that in hand:
///
///   1. **Probe before fetching.** `/address/{a}` returns a handful of integers and says whether an
///      address has ever been used. Most of a gap-limit window never has been, so asking that first
///      turns "utxos + history for 21 addresses" into 21 tiny requests plus real ones for the few
///      addresses that matter.
///   2. **Bounded concurrency.** Requests run `maxConcurrentRequests` at a time — enough to hide
///      latency, few enough not to look like a burst to the server or stall a phone's radio.
///
/// **A failed request fails the whole scan.** Partial results would be a wrong balance and a history
/// with holes, and a wallet that quietly under-reports is worse than one that says it couldn't sync
/// (Golden Rule §8).
struct ThunderEsploraBackend: ThunderBackend {
    let client: ThunderEsploraClient

    /// How many address requests are in flight at once.
    static let maxConcurrentRequests = 6

    /// Safety stop when paging one address's history. A page holds 25 rows, so this caps a single
    /// address at 500 transactions — far past any real wallet, and it means a server that kept
    /// answering full pages could never spin us forever.
    static let maxHistoryPages = 20

    init(client: ThunderEsploraClient) { self.client = client }

    // MARK: - ThunderBackend

    /// The `/address/{a}` stats route, run over the whole batch. Cheap enough to be the discovery
    /// probe: it returns a handful of integers per address and nothing else.
    ///
    /// The tip is checked first so an index that has walked no blocks costs **one** request rather
    /// than one per address — every one of those would answer zero. (That check duplicates the one in
    /// `scan`, which is a single extra tiny request per sync on the normal path, and worth it to keep
    /// each entry point independently correct.)
    func usedAddresses(_ addresses: [String]) async throws -> [String]? {
        do {
            _ = try await client.tipHeight()
        } catch ThunderBackendError.indexEmpty {
            return []   // nothing indexed ⇒ nothing used, and nothing to extend towards
        }
        let flags = try await concurrentMap(addresses) { address in
            (address, try await client.addressInfo(address).isUsed)
        }
        let used = Set(flags.filter(\.1).map(\.0))
        return addresses.filter { used.contains($0) }   // original order
    }

    func scan(addresses: [String], knownUsed: [String]?) async throws -> ThunderScan {
        let tipHeight: Int64
        do {
            tipHeight = try await client.tipHeight()
        } catch ThunderBackendError.indexEmpty {
            // The index is healthy but has walked no blocks, so there is genuinely nothing to find.
            // This is a fact, not a guess: with no blocks indexed every address route answers zero.
            return ThunderScan.empty
        }

        // 1. Which of these addresses has ever been used? Discovery has usually just asked, so reuse
        //    its answer rather than paying for the same probe twice. (Written out rather than with
        //    `??` — an autoclosure can't hold an `await`.)
        let used: [String]
        if let knownUsed {
            used = knownUsed
        } else {
            used = try await usedAddresses(addresses) ?? addresses
        }
        guard !used.isEmpty else { return ThunderScan.empty }

        // 2. Their UTXOs and their history. The address is carried alongside its rows because the
        //    index keys them by the route, not by a field — and the UTXO's address is exactly what
        //    signing needs to resolve a key for.
        let utxoPages = try await concurrentMap(used) { address in
            (address, try await client.addressUTXOs(address))
        }
        let txPages = try await concurrentMap(used) { address in
            try await allTransactions(of: address)
        }

        var utxos: [ThunderPointedOutput] = []
        for (address, rows) in utxoPages {
            guard let parsed = ThunderAddress(base58: address) else { continue }
            utxos.append(contentsOf: rows.compactMap { $0.pointedOutput(address: parsed) })
        }
        let transactions = ThunderEsploraHistory.build(txs: txPages.flatMap { $0 },
                                                       ours: Set(addresses),
                                                       tipHeight: tipHeight)
        return ThunderScan(utxos: utxos, transactions: transactions)
    }

    func spendableUTXOs(addresses: [String]) async throws -> [ThunderPointedOutput] {
        // No stats probe here: this fetches one thing per address, so the probe would cost exactly as
        // many requests as it saves.
        let pages = try await concurrentMap(addresses) { address in
            (address, try await client.addressUTXOs(address))
        }
        var out: [ThunderPointedOutput] = []
        for (address, rows) in pages {
            guard let parsed = ThunderAddress(base58: address) else { continue }
            out.append(contentsOf: rows.compactMap { $0.pointedOutput(address: parsed) })
        }
        return out
    }

    func submit(_ authorized: AuthorizedThunderTransaction) async throws -> String {
        try await client.broadcast(authorized)
    }

    // MARK: - Internals

    /// Every confirmed transaction touching one address, paging until the index returns a short page.
    ///
    /// The cursor is the **last** txid of a page, which the index resolves back to a height and
    /// continues below. A page that repeats the cursor's transaction would loop, so paging also stops
    /// if a page adds nothing new.
    private func allTransactions(of address: String) async throws -> [ThunderEsploraTx] {
        var out: [ThunderEsploraTx] = []
        var seen = Set<String>()
        var lastSeen: String? = nil
        for _ in 0..<Self.maxHistoryPages {
            let page = try await client.addressTxs(address, lastSeen: lastSeen)
            guard !page.isEmpty else { break }
            let fresh = page.filter { seen.insert($0.txid).inserted }
            out.append(contentsOf: fresh)
            // A full page of nothing new means the cursor isn't advancing — stop rather than spin.
            if fresh.isEmpty { break }
            guard let cursor = page.last?.txid else { break }
            lastSeen = cursor
        }
        return out
    }

    /// Run `work` over every element with at most `maxConcurrentRequests` in flight.
    ///
    /// Results come back in completion order, so every caller here either rebuilds the association
    /// itself (by carrying the address in the tuple) or doesn't depend on order.
    private func concurrentMap<Element: Sendable, Result: Sendable>(
        _ elements: [Element],
        _ work: @escaping @Sendable (Element) async throws -> Result
    ) async throws -> [Result] {
        guard !elements.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: Result.self) { group in
            var results: [Result] = []
            results.reserveCapacity(elements.count)
            var next = 0
            let firstBatch = min(Self.maxConcurrentRequests, elements.count)
            while next < firstBatch {
                let element = elements[next]
                group.addTask { try await work(element) }
                next += 1
            }
            while let result = try await group.next() {
                results.append(result)
                if next < elements.count {
                    let element = elements[next]
                    group.addTask { try await work(element) }
                    next += 1
                }
            }
            return results
        }
    }
}
