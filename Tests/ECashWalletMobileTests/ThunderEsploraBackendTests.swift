// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// `ThunderEsploraBackend`, including the request-shaping that makes a per-address index affordable on
/// a phone, and the same `ThunderService` flow the RPC suite drives — through the other backend.
@MainActor
@Suite struct ThunderEsploraBackendTests {

    private static let mnemonic = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"
    private static let address0 = "NKqSr4bQejFbKpd5yLQgWEiMJFx"

    /// A stubbed index. Answers by route, and records every path it was asked for so a test can assert
    /// on *how many* requests a sync made, not just what it concluded.
    private final class Index: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []

        var tipHeight = 100
        var indexIsEmpty = false
        /// Addresses the index has ever seen. Everything else answers zeroed stats.
        var usedAddresses: Set<String> = []
        /// address → its UTXO rows, as JSON array text.
        var utxosByAddress: [String: String] = [:]
        /// address → its deposit rows (`/address/{a}/deposits`), as JSON array text.
        var depositsByAddress: [String: String] = [:]
        /// address → pages of history, as JSON array text. Served in order, then `[]`.
        var txPagesByAddress: [String: [String]] = [:]
        /// A path suffix that should fail with a 500.
        var failingPathSuffix: String?
        /// A `/txs/chain/<cursor>` page that 404s — how the index answers a cursor it can't resolve.
        var notFoundCursor: String? = nil
        /// Addresses whose only activity is unconfirmed (`mempool_stats`, zero `chain_stats`).
        var mempoolOnlyAddresses: Set<String> = []

        var paths: [String] { lock.withLock { _paths } }
        func paths(containing needle: String) -> [String] { paths.filter { $0.contains(needle) } }

        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            let path = request.url?.path ?? ""
            // Which page of THIS address's history is being asked for. Counted per address, not per
            // path: paging puts the cursor in the path, so every page after the first has a different
            // one, and counting by path would serve page 0 forever.
            let address = Self.address(in: path)
            let pageIndex = lock.withLock { () -> Int in
                let prior = _paths.filter { $0.contains("/txs/chain") && Self.address(in: $0) == address }.count
                _paths.append(path)
                return prior
            }
            if let failing = failingPathSuffix, path.hasSuffix(failing) {
                return (Data("boom".utf8), 500)
            }
            if path.hasSuffix("/blocks/tip/height") {
                return indexIsEmpty
                    ? (Data("the index holds no blocks yet".utf8), 404)
                    : (Data("\(tipHeight)".utf8), 200)
            }
            if path.hasSuffix("/utxo") {
                return (Data((utxosByAddress[address] ?? "[]").utf8), 200)
            }
            if path.hasSuffix("/deposits") {
                return (Data((depositsByAddress[address] ?? "[]").utf8), 200)
            }
            if let cursor = notFoundCursor, path.hasSuffix("/txs/chain/\(cursor)") {
                return (Data("not found".utf8), 404)
            }
            if path.contains("/txs/chain") {
                let pages = txPagesByAddress[address] ?? []
                return (Data((pageIndex < pages.count ? pages[pageIndex] : "[]").utf8), 200)
            }
            if path.contains("/address/") {
                let count = usedAddresses.contains(address) ? 3 : 0
                let pending = mempoolOnlyAddresses.contains(address) ? 1 : 0
                return (Data("""
                {"address":"\(address)",
                 "chain_stats":{"funded_txo_count":\(count),"funded_txo_sum":0,
                                "spent_txo_count":0,"spent_txo_sum":0,"tx_count":\(count)},
                 "mempool_stats":{"funded_txo_count":\(pending),"funded_txo_sum":0,
                                  "spent_txo_count":0,"spent_txo_sum":0,"tx_count":\(pending)}}
                """.utf8), 200)
            }
            return (Data("[]".utf8), 200)
        }

        /// `/thunder/address/{a}/…` → `{a}`.
        private static func address(in path: String) -> String {
            let parts = path.components(separatedBy: "/")
            guard let index = parts.firstIndex(of: "address"), index + 1 < parts.count else { return "" }
            return parts[index + 1]
        }

        func backend() -> ThunderEsploraBackend {
            ThunderEsploraBackend(client: ThunderEsploraClient(endpoint: "https://index.example/thunder") {
                [self] in try await fetch($0)
            })
        }

        @MainActor
        func service(indexStore: ThunderAddressIndexStoring = InMemoryThunderAddressIndexStore())
        -> ThunderService {
            ThunderService(loadMnemonic: { _ in ThunderEsploraBackendTests.mnemonic },
                           makeBackend: { [self] in backend() },
                           indexStore: indexStore,
                           firstSeenStore: InMemoryThunderFirstSeenStore(),
                           accountKeyStore: InMemoryThunderAccountKeyStore(),
                           now: { 1_800_000_000 })
        }
    }

    /// The wallet's first `count` addresses — discovery tests need to place coins at a known index.
    private static func addresses(count: Int) throws -> [String] {
        try ThunderWallet(mnemonic: mnemonic).addresses(count: count).map(\.base58)
    }

    private static func utxoJSON(value: Int, vout: Int = 0, height: Int = 90,
                                 txid: String = String(repeating: "11", count: 32),
                                 confirmed: Bool = true) -> String {
        let status = confirmed
            ? #"{"confirmed":true,"block_height":\#(height),"block_hash":"\#(String(repeating: "ab", count: 32))","block_time":1750000000}"#
            : #"{"confirmed":false,"block_height":null,"block_hash":null,"block_time":null}"#
        return """
        [{"txid":"\(txid)","vout":\(vout),"value":\(value),
          "status":\(status),
          "outpoint_kind":"regular","height_exact":true,"content_type":"value"}]
        """
    }

    private static func txJSON(txid: String, toAddress: String, value: Int, height: Int = 90,
                               confirmed: Bool = true) -> String {
        let status = confirmed
            ? #"{"confirmed":true,"block_height":\#(height),"block_hash":"\#(String(repeating: "ab", count: 32))","block_time":1750000000}"#
            : #"{"confirmed":false,"block_height":null,"block_hash":null,"block_time":null}"#
        return """
        [{"txid":"\(txid)","version":0,"locktime":0,"size":300,"weight":1200,"fee":200,
          "vin":[{"txid":"\(String(repeating: "99", count: 32))","vout":0,
                  "prevout":{"scriptpubkey":"","scriptpubkey_asm":"",
                             "scriptpubkey_type":"sidechain_address",
                             "scriptpubkey_address":"3SomeoneElseXXXXXXXXXXXXXXXXX","value":\(value + 500),
                             "outpoint_kind":"regular","content_type":"value"},
                  "scriptsig":"","witness":[],"is_coinbase":false,"sequence":0}],
          "vout":[{"scriptpubkey":"","scriptpubkey_asm":"",
                   "scriptpubkey_type":"sidechain_address",
                   "scriptpubkey_address":"\(toAddress)","value":\(value),
                   "outpoint_kind":"regular","content_type":"value"}],
          "status":\(status)}]
        """
    }

    /// One `/txs/chain` page from several single-row fixtures.
    private static func page(_ rows: [String]) -> String {
        "[" + rows.map { String($0.dropFirst().dropLast()) }.joined(separator: ",") + "]"
    }

    /// A FULL page (`historyPageSize` rows), txids "<prefix>0".."<prefix>24", heights descending.
    private static func fullPage(prefix: String, fromHeight: Int) -> String {
        page((0..<ThunderEsploraBackend.historyPageSize).map {
            txJSON(txid: "\(prefix)\($0)", toAddress: address0, value: 1_000, height: fromHeight - $0)
        })
    }

    // MARK: - Request shaping

    /// The stats probe is the whole reason a per-address index is usable here. An unused address must
    /// cost exactly one small request, not three.
    @Test func unusedAddressesCostOneProbeAndNoMore() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = Self.utxoJSON(value: 5_000)

        _ = try await index.service().sync(walletId: "w1")

        // The window is revealed(0) + gap limit + 1 = 21 addresses, each probed once.
        #expect(index.paths(containing: "/address/").filter { !$0.contains("/utxo") && !$0.contains("/txs") && !$0.contains("/deposits") }.count == 21)
        // …but only the one used address was fetched in full.
        #expect(index.paths(containing: "/utxo").count == 1)
        #expect(index.paths(containing: "/txs/chain").count == 1)
    }

    /// The send path fetches one thing per address, so a probe would cost exactly as many requests as
    /// it saves — it must not do one.
    @Test func theSendPathSkipsTheProbe() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = Self.utxoJSON(value: 50_000)

        let utxos = try await index.backend().spendableUTXOs(addresses: [Self.address0, "3OtherXXXXXXXXXXXXXXXXXXXXXXX"])
        #expect(utxos.count == 1)
        #expect(index.paths(containing: "/utxo").count == 2)
        #expect(index.paths(containing: "/txs/chain").isEmpty)
        // No bare /address/{a} stats call.
        #expect(index.paths.allSatisfy { !$0.hasSuffix("/address/\(Self.address0)") })
    }

    // MARK: - Empty index

    /// The live endpoint's current state. With no blocks walked, every address route answers zero
    /// anyway — so an empty result is a fact here, not a guess, and the sync must succeed rather than
    /// surface a connection error.
    @Test func anEmptyIndexSyncsToZeroRatherThanFailing() async throws {
        let index = Index()
        index.indexIsEmpty = true

        let balance = try await index.service().sync(walletId: "w1")
        #expect(balance.sats == 0)
        // It stopped at the tip probe rather than fanning out over the window — one request per
        // entry point (discovery, then scan), and not one per address.
        #expect(index.paths(containing: "/address/").isEmpty)
        #expect(index.paths(containing: "/blocks/tip/height").count == 2)
    }

    // MARK: - Scanning

    @Test func syncSumsUTXOsAndBuildsDatedHistory() async throws {
        let index = Index()
        index.tipHeight = 100
        index.usedAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = Self.utxoJSON(value: 42_000, height: 90)
        index.txPagesByAddress[Self.address0] = [Self.txJSON(txid: "aa", toAddress: Self.address0,
                                                             value: 42_000, height: 90)]

        let service = index.service()
        let balance = try await service.sync(walletId: "w1")
        #expect(balance.sats == 42_000)

        let history = try service.transactions(walletId: "w1")
        #expect(history.count == 1)
        // The point of the whole change: real height, real time, real depth — none of which the
        // node-RPC path can produce.
        #expect(history[0].blockHeight == 90)
        #expect(history[0].confirmations == 11)
        #expect(history[0].timestampEpochSeconds == 1_750_000_000)
        #expect(history[0].netSats == 42_000)
    }

    /// A wallet funded only by a BIP300 deposit: the balance comes from `/utxo`, but `/txs` is EMPTY
    /// (a deposit isn't a Thunder transaction). The history row has to come from `/deposits`. This is
    /// the real betanet shape (deposit f83c5c7a…, credited at Thunder height 839, no block time).
    @Test func aDepositShowsUpInHistory() async throws {
        let deposit = """
        [{"txid":"f83c5c7a975798aefa35a98299b31bebcf4dda5edf885bd6f893244a1b2688c5","vout":0,"value":10000000,
          "status":{"confirmed":true,"block_height":839,
                    "block_hash":"d00eaf363652d161f014f6fef2e3b56861455472cd39e94050952621a9d82a51","block_time":null},
          "outpoint_kind":"deposit","height_exact":true,"content_type":"value","content":{"Value":10000000}}]
        """
        let index = Index()
        index.tipHeight = 859
        index.usedAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = deposit
        index.depositsByAddress[Self.address0] = deposit

        let service = index.service()
        let balance = try await service.sync(walletId: "w1")
        #expect(balance.sats == 10_000_000)

        let history = try service.transactions(walletId: "w1")
        #expect(history.count == 1)
        let row = try #require(history.first)
        #expect(row.txid == "f83c5c7a975798aefa35a98299b31bebcf4dda5edf885bd6f893244a1b2688c5")   // the MAINCHAIN tx
        #expect(row.netSats == 10_000_000)
        #expect(row.isReceived)
        #expect(row.isSidechainDeposit)
        #expect(row.sidechainDepositSlot == 9)
        #expect(row.sidechainDepositAddress == Self.address0)
        #expect(row.blockHeight == 839)
        #expect(row.confirmations == 21)
        // The index gives deposits no block time, so the service dates the row by when this device
        // first saw it, like any undated Thunder row. The deposit fields must survive that re-dating.
        #expect(row.timestampEpochSeconds != nil)
        #expect(row.feeSats == nil)                 // paid on the mainchain, not by this wallet
        #expect(index.paths(containing: "/deposits").count == 1)   // only the used address is asked
    }

    /// Deposits are keyed by outpoint, so the same deposit reported twice is one row, and anything
    /// that isn't a deposit on that route is ignored.
    @Test func depositRowsAreDeduplicatedAndFiltered() {
        let status = ThunderEsploraStatus(confirmed: true, blockHeight: 10, blockHash: nil, blockTime: nil)
        func row(_ txid: String, kind: String) throws -> ThunderEsploraUTXO {
            try JSONDecoder().decode(ThunderEsploraUTXO.self, from: Data("""
            {"txid":"\(txid)","vout":0,"value":500,"status":{"confirmed":true,"block_height":10},
             "outpoint_kind":"\(kind)"}
            """.utf8))
        }
        _ = status
        let rows = (try? [row("aa", kind: "deposit"), row("aa", kind: "deposit"), row("bb", kind: "regular")]) ?? []
        let history = ThunderEsploraHistory.build(txs: [], deposits: [("addr", rows)], ours: ["addr"], tipHeight: 10)
        #expect(history.map(\.txid) == ["aa"])
    }

    /// A wallet's history is paged 25 at a time. Paging must follow the cursor and stop on a short
    /// page — and must not be fooled into looping by a server that repeats one.
    @Test func historyPagesUntilAShortPage() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.txPagesByAddress[Self.address0] = [
            Self.fullPage(prefix: "p", fromHeight: 200),
            Self.txJSON(txid: "zz", toAddress: Self.address0, value: 2_000, height: 90),   // short → last
        ]

        let service = index.service()
        _ = try await service.sync(walletId: "w1")

        let history = try service.transactions(walletId: "w1")
        #expect(history.count == ThunderEsploraBackend.historyPageSize + 1)
        #expect(history.first?.txid == "p0")    // newest first by height
        #expect(history.last?.txid == "zz")
        let pages = index.paths(containing: "/txs/chain")
        #expect(pages.count == 2)
        #expect(pages.last?.hasSuffix("/txs/chain/p24") == true)   // cursor = last row of page one
    }

    @Test func aRepeatedPageStopsPagingInsteadOfLooping() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        // The same FULL page forever — a server that ignores the cursor.
        index.txPagesByAddress[Self.address0] = Array(repeating: Self.fullPage(prefix: "p", fromHeight: 200), count: 50)

        let service = index.service()
        _ = try await service.sync(walletId: "w1")

        #expect(try service.transactions(walletId: "w1").count == ThunderEsploraBackend.historyPageSize)
        // Stopped as soon as a page added nothing new, well inside the page cap.
        #expect(index.paths(containing: "/txs/chain").count == 2)
    }

    /// Regression (2026-09-30, first live Thunder send on betanet): the index lists the just-sent,
    /// UNCONFIRMED tx at the top of page one, and paging from it 404s. The sync must succeed and show
    /// the tx as pending instead of failing with "Couldn't reach the network".
    @Test func anUnconfirmedTxDoesNotBreakSync() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.notFoundCursor = "new"
        index.txPagesByAddress[Self.address0] = [Self.page([
            Self.txJSON(txid: "new", toAddress: Self.address0, value: 3_000, confirmed: false),
            Self.txJSON(txid: "old", toAddress: Self.address0, value: 1_000, height: 90),
        ])]

        let service = index.service()
        _ = try await service.sync(walletId: "w1")

        let history = try service.transactions(walletId: "w1")
        #expect(Set(history.map(\.txid)) == ["new", "old"])
        #expect(history.first { $0.txid == "new" }?.confirmations == 0)
        #expect(index.paths(containing: "/txs/chain").count == 1)
    }

    /// A full page whose top rows are unconfirmed pages from its last CONFIRMED row, never from one
    /// that has no height.
    @Test func pagingNeverUsesAnUnconfirmedCursor() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.notFoundCursor = "u"
        var rows = [Self.txJSON(txid: "u", toAddress: Self.address0, value: 3_000, confirmed: false)]
        rows += (0..<(ThunderEsploraBackend.historyPageSize - 1)).map {
            Self.txJSON(txid: "c\($0)", toAddress: Self.address0, value: 1_000, height: 200 - $0)
        }
        // Make the unconfirmed row the LAST one too, to prove the cursor skips it.
        rows.append(rows.removeFirst())
        index.txPagesByAddress[Self.address0] = [Self.page(rows),
                                                 Self.txJSON(txid: "tail", toAddress: Self.address0, value: 1_000, height: 10)]

        let service = index.service()
        _ = try await service.sync(walletId: "w1")

        #expect(try service.transactions(walletId: "w1").contains { $0.txid == "tail" })
        #expect(index.paths(containing: "/txs/chain").last?.hasSuffix("/txs/chain/c23") == true)
    }

    /// Regression (2026-09-30): right after a send, the change address's ONLY activity is the
    /// unconfirmed send. It must still count as used, or its coin is never fetched and the wallet
    /// reads zero.
    @Test func anAddressWithOnlyUnconfirmedActivityIsScanned() async throws {
        let index = Index()
        index.mempoolOnlyAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = Self.utxoJSON(value: 29_730, confirmed: false)

        let service = index.service()
        _ = try await service.sync(walletId: "w1")
        #expect(try service.pendingBalance(walletId: "w1") == Amount(sats: 29_730))
    }

    /// The node can't spend an output that isn't in a block yet (its utreexo accumulator only holds
    /// confirmed coins), so an unconfirmed coin is PENDING: in the pending balance, out of the spendable
    /// balance and out of coin selection.
    @Test func unconfirmedCoinsArePendingNotSpendable() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = Self.page([
            Self.utxoJSON(value: 5_000, vout: 0),
            Self.utxoJSON(value: 29_730, vout: 1, txid: String(repeating: "22", count: 32), confirmed: false),
        ])

        let service = index.service()
        #expect(try await service.sync(walletId: "w1") == Amount(sats: 5_000))
        #expect(try service.pendingBalance(walletId: "w1") == Amount(sats: 29_730))

        // Sending more than the confirmed 5,000 fails up front — it never offers the pending coin.
        do {
            _ = try await service.send(walletId: "w1", to: Self.address0, amount: Amount(sats: 10_000),
                                       feeRate: FeeRate(satPerVByte: 1))
            Issue.record("expected insufficientFunds")
        } catch let error as ThunderError {
            guard case .insufficientFunds = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    /// A cursor the index can no longer resolve ends the history; it doesn't fail the sync.
    @Test func aNotFoundFollowUpPageEndsHistory() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.notFoundCursor = "p24"
        index.txPagesByAddress[Self.address0] = [Self.fullPage(prefix: "p", fromHeight: 200)]

        let service = index.service()
        _ = try await service.sync(walletId: "w1")

        #expect(try service.transactions(walletId: "w1").count == ThunderEsploraBackend.historyPageSize)
    }

    // MARK: - Failure

    /// A partial scan is a wrong balance and a history with holes. Failing the sync is the honest
    /// outcome — the UI already has a sync-failed state (Golden Rule §8).
    @Test func oneFailedRequestFailsTheWholeScan() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = Self.utxoJSON(value: 5_000)
        index.failingPathSuffix = "/utxo"

        await #expect(throws: ThunderBackendError.self) {
            _ = try await index.service().sync(walletId: "w1")
        }
    }

    // MARK: - Send, end to end

    @Test func sendSelectsSignsAndSubmitsOverTheIndex() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.utxosByAddress[Self.address0] = Self.utxoJSON(value: 100_000)

        // The stub answers `[]` for POST /tx, which isn't a txid — so use a client that returns one.
        final class Submitting: @unchecked Sendable {
            var body: Data?
            func fetch(_ request: URLRequest, index: Index) async throws -> (Data, Int) {
                if request.httpMethod == "POST" {
                    body = request.httpBody
                    return (Data("feedbeef".utf8), 200)
                }
                return try await index.fetch(request)
            }
        }
        let submitting = Submitting()
        let service = ThunderService(
            loadMnemonic: { _ in Self.mnemonic },
            makeBackend: {
                ThunderEsploraBackend(client: ThunderEsploraClient(endpoint: "https://index.example/thunder") {
                    try await submitting.fetch($0, index: index)
                })
            },
            indexStore: InMemoryThunderAddressIndexStore(),
            firstSeenStore: InMemoryThunderFirstSeenStore(),
            accountKeyStore: InMemoryThunderAccountKeyStore(),
            now: { 1_800_000_000 })

        let tx = try await service.send(walletId: "w1", to: Self.address0,
                                        amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1))
        #expect(tx.txid == "feedbeef")
        #expect(tx.netSats < 0)

        // A real authorized transaction went out, signed locally — the seed never left the phone.
        let posted = try #require(submitting.body)
        let json = try #require(try JSONSerialization.jsonObject(with: posted) as? [String: Any])
        #expect(json["transaction"] != nil)
        #expect((json["authorizations"] as? [Any])?.isEmpty == false)
    }

    // MARK: - Gap-limit discovery

    /// **The restore case.** `revealedIndex` is local device state, so a wallet restored onto a new
    /// phone starts at 0 and the initial window covers only indices 0…20. A wallet that had been used
    /// further down would show a partial balance. Discovery walks out and finds the rest.
    ///
    /// Index 18 is inside the initial window's trailing stretch, which is what opens the extension
    /// that reaches 25. That ordering is the gap-limit rule, not an accident — see
    /// `discoveryStopsAfterAnUntouchedStretch` for the other side of it.
    @Test func discoveryFindsCoinsPastTheInitialWindow() async throws {
        let index = Index()
        let addresses = try Self.addresses(count: 60)
        index.usedAddresses = [addresses[18], addresses[25]]
        index.utxosByAddress[addresses[18]] = Self.utxoJSON(value: 3_000)
        index.utxosByAddress[addresses[25]] = Self.utxoJSON(value: 77_000)

        let store = InMemoryThunderAddressIndexStore()
        let balance = try await index.service(indexStore: store).sync(walletId: "w1")

        #expect(balance.sats == 80_000)
        // …and the discovery is recorded, so it costs nothing next time — and the send path, which
        // never runs discovery, sees the same window.
        #expect(store.revealedIndex(walletId: "w1") == 25)
    }

    /// The walk keeps going as long as coins keep turning up — one extension isn't enough when the
    /// used addresses are spread out.
    @Test func discoveryKeepsWalkingWhileAddressesStayUsed() async throws {
        let index = Index()
        let addresses = try Self.addresses(count: 120)
        // 15 → 35 → 55: each sits in the trailing stretch of the window the previous one opened up.
        for i in [15, 35, 55] {
            index.usedAddresses.insert(addresses[i])
            index.utxosByAddress[addresses[i]] = Self.utxoJSON(value: 1_000)
        }

        let store = InMemoryThunderAddressIndexStore()
        let balance = try await index.service(indexStore: store).sync(walletId: "w1")

        #expect(balance.sats == 3_000)
        #expect(store.revealedIndex(walletId: "w1") == 55)
    }

    /// …and stops once a whole gap-limit stretch is untouched, rather than walking the chain forever.
    @Test func discoveryStopsAfterAnUntouchedStretch() async throws {
        let index = Index()
        let addresses = try Self.addresses(count: 200)
        index.usedAddresses = [addresses[0]]
        index.utxosByAddress[addresses[0]] = Self.utxoJSON(value: 500)
        // A coin far out of reach — deliberately NOT found, because 21…120 are all unused.
        index.usedAddresses.insert(addresses[150])
        index.utxosByAddress[addresses[150]] = Self.utxoJSON(value: 999_999)

        let store = InMemoryThunderAddressIndexStore()
        let balance = try await index.service(indexStore: store).sync(walletId: "w1")

        #expect(balance.sats == 500)
        #expect(store.revealedIndex(walletId: "w1") == 0)
        // Only the initial window was probed: nothing in its trailing stretch was used.
        let probes = index.paths(containing: "/address/").filter { !$0.contains("/utxo") && !$0.contains("/txs") && !$0.contains("/deposits") }
        #expect(probes.count == 21)
    }

    /// A server that calls every address used must not make us derive forever.
    @Test func discoveryIsCappedAgainstAServerThatClaimsEverythingIsUsed() async throws {
        let index = Index()
        let addresses = try Self.addresses(count: 600)
        index.usedAddresses = Set(addresses)

        let store = InMemoryThunderAddressIndexStore()
        _ = try await index.service(indexStore: store).sync(walletId: "w1")

        // Initial window + at most maxDiscoveryRounds batches of gapLimit.
        let ceiling = 21 + ThunderService.maxDiscoveryRounds * Int(ThunderService.gapLimit)
        #expect(store.revealedIndex(walletId: "w1") < UInt32(ceiling))
        let probes = index.paths(containing: "/address/").filter { !$0.contains("/utxo") && !$0.contains("/txs") && !$0.contains("/deposits") }
        #expect(probes.count <= ceiling)
    }

    /// The node RPC can't answer "is this address used?" without a full UTXO-table scan, so it opts
    /// out of discovery and keeps the fixed window it has always had.
    @Test func theNodeRPCBackendDoesNotExtendTheWindow() async throws {
        let backend = ThunderRPCBackend(client: ThunderRPCClient(endpoint: "http://127.0.0.1:6009") { _ in
            (Data(#"{"jsonrpc":"2.0","id":1,"result":[]}"#.utf8), 200)
        })
        #expect(try await backend.usedAddresses(["a", "b"]) == nil)
    }
}
