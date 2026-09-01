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
    private static let address0 = "38VvRdmcQREr1UAcZma98WLFVpAp"

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
        /// address → pages of history, as JSON array text. Served in order, then `[]`.
        var txPagesByAddress: [String: [String]] = [:]
        /// A path suffix that should fail with a 500.
        var failingPathSuffix: String?

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
            if path.contains("/txs/chain") {
                let pages = txPagesByAddress[address] ?? []
                return (Data((pageIndex < pages.count ? pages[pageIndex] : "[]").utf8), 200)
            }
            if path.contains("/address/") {
                let count = usedAddresses.contains(address) ? 3 : 0
                return (Data("""
                {"address":"\(address)",
                 "chain_stats":{"funded_txo_count":\(count),"funded_txo_sum":0,
                                "spent_txo_count":0,"spent_txo_sum":0,"tx_count":\(count)},
                 "mempool_stats":{"funded_txo_count":0,"funded_txo_sum":0,
                                  "spent_txo_count":0,"spent_txo_sum":0,"tx_count":0}}
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
                           now: { 1_800_000_000 })
        }
    }

    /// The wallet's first `count` addresses — discovery tests need to place coins at a known index.
    private static func addresses(count: Int) throws -> [String] {
        try ThunderWallet(mnemonic: mnemonic).addresses(count: count).map(\.base58)
    }

    private static func utxoJSON(value: Int, vout: Int = 0, height: Int = 90,
                                 txid: String = String(repeating: "11", count: 32)) -> String {
        """
        [{"txid":"\(txid)","vout":\(vout),"value":\(value),
          "status":{"confirmed":true,"block_height":\(height),
                    "block_hash":"\(String(repeating: "ab", count: 32))","block_time":1750000000},
          "outpoint_kind":"regular","height_exact":true,"content_type":"value"}]
        """
    }

    private static func txJSON(txid: String, toAddress: String, value: Int, height: Int = 90) -> String {
        """
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
          "status":{"confirmed":true,"block_height":\(height),
                    "block_hash":"\(String(repeating: "ab", count: 32))","block_time":1750000000}}]
        """
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
        #expect(index.paths(containing: "/address/").filter { !$0.contains("/utxo") && !$0.contains("/txs") }.count == 21)
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

    /// A wallet's history is paged 25 at a time. Paging must follow the cursor and stop on a short
    /// page — and must not be fooled into looping by a server that repeats one.
    @Test func historyPagesUntilAShortPage() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        index.txPagesByAddress[Self.address0] = [
            Self.txJSON(txid: "aa", toAddress: Self.address0, value: 1_000, height: 95),
            Self.txJSON(txid: "bb", toAddress: Self.address0, value: 2_000, height: 90),
            "[]",
        ]

        let service = index.service()
        _ = try await service.sync(walletId: "w1")

        let history = try service.transactions(walletId: "w1")
        #expect(history.map(\.txid) == ["aa", "bb"])       // newest first by height
        #expect(index.paths(containing: "/txs/chain").count == 3)
    }

    @Test func aRepeatedPageStopsPagingInsteadOfLooping() async throws {
        let index = Index()
        index.usedAddresses = [Self.address0]
        // The same page forever — a server that ignores the cursor.
        let page = Self.txJSON(txid: "aa", toAddress: Self.address0, value: 1_000)
        index.txPagesByAddress[Self.address0] = Array(repeating: page, count: 50)

        let service = index.service()
        _ = try await service.sync(walletId: "w1")

        #expect(try service.transactions(walletId: "w1").count == 1)
        // Stopped as soon as a page added nothing new, well inside the page cap.
        #expect(index.paths(containing: "/txs/chain").count == 2)
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
        let probes = index.paths(containing: "/address/").filter { !$0.contains("/utxo") && !$0.contains("/txs") }
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
        let probes = index.paths(containing: "/address/").filter { !$0.contains("/utxo") && !$0.contains("/txs") }
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
