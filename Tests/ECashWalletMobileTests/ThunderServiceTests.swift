// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// `ThunderService` end to end over the **node-RPC backend**, against a stubbed node: address
/// derivation and the revealed-index discipline are local, while balance / sync / send run the real
/// thin-client flow (derive → `get_utxos` → select → sign → `submit_transaction`) with the RPC replaced
/// by canned JSON.
///
/// The Esplora backend is covered by `ThunderEsploraBackendTests`; both suites drive the same
/// `ThunderService`, which is the point of the `ThunderBackend` seam.
@MainActor
@Suite struct ThunderServiceTests {

    private static let mnemonic = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"
    /// Index-0 address for the mnemonic above (pinned in ThunderWalletTests).
    private static let address0 = "NKqSr4bQejFbKpd5yLQgWEiMJFx"

    /// A service whose RPC returns `utxosJSON` for `get_utxos` and `txid` for `submit_transaction`,
    /// recording every request body it was sent.
    private static func service(utxosJSON: String = "[]",
                                stxosJSON: String = "[]",
                                stxosFails: Bool = false,
                                submitTxid: String = "aa",
                                requests: RequestLog = RequestLog(),
                                indexStore: ThunderAddressIndexStoring = InMemoryThunderAddressIndexStore(),
                                firstSeenStore: ThunderFirstSeenStoring = InMemoryThunderFirstSeenStore(),
                                accountKeyStore: ThunderAccountKeyStoring = InMemoryThunderAccountKeyStore(),
                                mnemonicReads: MnemonicReads = MnemonicReads(),
                                mnemonic: String? = mnemonic) -> ThunderService {
        ThunderService(
            loadMnemonic: { _ in mnemonicReads.count += 1; return mnemonic },
            makeBackend: {
                ThunderRPCBackend(client: ThunderRPCClient(endpoint: "http://127.0.0.1:6009") { request in
                    let body = request.httpBody ?? Data()
                    requests.append(body)
                    let method = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?
                        .flatMap { $0["method"] as? String } ?? ""
                    switch method {
                    case "get_utxos":
                        return (Data(#"{"jsonrpc":"2.0","id":1,"result":\#(utxosJSON)}"#.utf8), 200)
                    case "get_stxos":
                        if stxosFails {
                            return (Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#.utf8), 200)
                        }
                        return (Data(#"{"jsonrpc":"2.0","id":1,"result":\#(stxosJSON)}"#.utf8), 200)
                    case "submit_transaction":
                        return (Data(#"{"jsonrpc":"2.0","id":1,"result":"\#(submitTxid)"}"#.utf8), 200)
                    default:
                        return (Data(#"{"jsonrpc":"2.0","id":1,"result":0}"#.utf8), 200)
                    }
                })
            },
            indexStore: indexStore,
            firstSeenStore: firstSeenStore,
            accountKeyStore: accountKeyStore)
    }

    private static func utxoJSON(address: String, sats: UInt64, vout: Int,
                                txid: String = String(repeating: "11", count: 32)) -> String {
        """
        {"outpoint":{"Regular":{"txid":"\(txid)","vout":\(vout)}},
         "output":{"address":"\(address)","content":{"Value":\(sats)}}}
        """
    }

    // MARK: - Addresses

    @Test func unusedAddressIsIndexZeroGolden() async throws {
        let service = Self.service()
        let info = try await service.receiveAddress(walletId: "w1", unused: true)
        #expect(info.address == Self.address0)
        #expect(info.index == 0)
    }

    @Test func newAddressAdvancesAndDiffersFromDefault() async throws {
        let service = Self.service()
        let a = try await service.receiveAddress(walletId: "w1", unused: false)
        let b = try await service.receiveAddress(walletId: "w1", unused: false)
        #expect(a.index == 1)
        #expect(b.index == 2)
        #expect(a.address != b.address)
    }

    @Test func revealedIndexIsPerWallet() async throws {
        let service = Self.service()
        _ = try await service.receiveAddress(walletId: "w1", unused: false)
        #expect(try await service.receiveAddress(walletId: "w2", unused: false).index == 1)
    }

    /// The reason the index is persisted at all: a relaunch must not start handing out index 0 again
    /// (address reuse), and the next sync's scan window has to still cover what we revealed.
    @Test func revealedIndexSurvivesANewServiceInstance() async throws {
        let store = InMemoryThunderAddressIndexStore()
        let first = Self.service(indexStore: store)
        _ = try await first.receiveAddress(walletId: "w1", unused: false)   // → 1
        _ = try await first.receiveAddress(walletId: "w1", unused: false)   // → 2

        let relaunched = Self.service(indexStore: store)
        #expect(try await relaunched.receiveAddress(walletId: "w1", unused: true).index == 2)
        #expect(try await relaunched.receiveAddress(walletId: "w1", unused: false).index == 3)
    }

    @Test func missingMnemonicThrowsTyped() async {
        let service = Self.service(mnemonic: nil)
        do {
            _ = try await service.receiveAddress(walletId: "w1", unused: true)
            Issue.record("expected mnemonicUnavailable")
        } catch let error as ThunderError {
            #expect(error == .mnemonicUnavailable(walletId: "w1"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - Watch-only (thunder-rust 0.18 non-hardened address keys)

    /// Addresses come from the cached account PUBLIC key: the mnemonic is read once — to compute that
    /// key — and never again for receive, change or sync. Only signing reads it after that.
    @Test func addressesNeedTheMnemonicOnlyOnce() async throws {
        let reads = MnemonicReads()
        let service = Self.service(mnemonicReads: reads)
        _ = try await service.receiveAddress(walletId: "w1", unused: true)
        _ = try await service.receiveAddress(walletId: "w1", unused: false)
        _ = try await service.sync(walletId: "w1")
        #expect(reads.count == 1)
    }

    @Test func cachedAccountKeyServesAddressesWithoutAnyMnemonic() async throws {
        let store = InMemoryThunderAccountKeyStore()
        _ = try await Self.service(accountKeyStore: store).receiveAddress(walletId: "w1", unused: true)
        // A relaunch where the Keychain is unavailable still lists addresses — and the same ones.
        let watchOnly = Self.service(accountKeyStore: store, mnemonic: nil)
        #expect(try await watchOnly.receiveAddress(walletId: "w1", unused: true).address == Self.address0)
    }

    @Test func signingStillReadsTheMnemonic() async throws {
        let reads = MnemonicReads()
        let service = Self.service(utxosJSON: "[\(Self.utxoJSON(address: Self.address0, sats: 50_000, vout: 0))]",
                                   mnemonicReads: reads)
        _ = try await service.sync(walletId: "w1")
        let before = reads.count
        _ = try await service.send(walletId: "w1", to: Self.address0, amount: Amount(sats: 10_000),
                                   feeRate: FeeRate(satPerVByte: 1))
        #expect(reads.count == before + 1)
    }

    @Test func forgetPurgesEveryPerWalletStore() async throws {
        let index = InMemoryThunderAddressIndexStore()
        let firstSeen = InMemoryThunderFirstSeenStore()
        let accountKeys = InMemoryThunderAccountKeyStore()
        let service = Self.service(indexStore: index, firstSeenStore: firstSeen, accountKeyStore: accountKeys)
        _ = try await service.receiveAddress(walletId: "w1", unused: false)
        _ = try await service.receiveAddress(walletId: "w2", unused: false)
        firstSeen.record(txids: ["aa"], walletId: "w1", now: 1)

        service.forget(walletId: "w1")
        #expect(index.revealedIndex(walletId: "w1") == 0)
        #expect(firstSeen.firstSeen(walletId: "w1").isEmpty)
        #expect(accountKeys.accountKey(walletId: "w1") == nil)
        // Only the removed wallet.
        #expect(index.revealedIndex(walletId: "w2") == 1)
        #expect(accountKeys.accountKey(walletId: "w2") != nil)
    }

    // MARK: - Balance / sync

    @Test func balanceIsZeroBeforeTheFirstSync() throws {
        #expect(try Self.service().balance(walletId: "w1").sats == 0)
        #expect(try Self.service().pendingBalance(walletId: "w1").sats == 0)
    }

    @Test func syncSumsTheNodesUtxos() async throws {
        let json = "[\(Self.utxoJSON(address: Self.address0, sats: 7_000, vout: 0)),"
            + "\(Self.utxoJSON(address: Self.address0, sats: 3_000, vout: 1))]"
        let service = Self.service(utxosJSON: json)
        #expect(try await service.sync(walletId: "w1").sats == 10_000)
        #expect(try service.balance(walletId: "w1").sats == 10_000)   // cached for the synchronous read
    }

    @Test func syncScansTheRevealedWindowPlusTheGapLimit() async throws {
        let store = InMemoryThunderAddressIndexStore()
        let log = RequestLog()
        let service = Self.service(requests: log, indexStore: store)
        _ = try await service.receiveAddress(walletId: "w1", unused: false)   // revealed → 1
        _ = try await service.sync(walletId: "w1")

        let params = try #require(log.lastParams(method: "get_utxos") as? [[String]])
        // indices 0 ... revealed(1) + gapLimit(20)
        #expect(params[0].count == Int(ThunderService.gapLimit) + 2)
        #expect(params[0].first == Self.address0)
    }

    @Test func withdrawalOutputsAreExcludedFromBalance() async throws {
        let json = """
        [\(Self.utxoJSON(address: Self.address0, sats: 1_000, vout: 0)),
         {"outpoint":{"Regular":{"txid":"\(String(repeating: "22", count: 32))","vout":0}},
          "output":{"address":"\(Self.address0)",
                    "content":{"Withdrawal":{"value_sats":9000,"main_fee_sats":100,
                                             "main_address":"1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"}}}}]
        """
        let service = Self.service(utxosJSON: json)
        // Only the spendable 1000 counts — a withdrawal output is on its way off the sidechain and
        // consensus refuses to let anyone spend it.
        #expect(try await service.sync(walletId: "w1").sats == 1_000)
    }

    // MARK: - History

    /// Before a sync there's nothing to show — an empty list, not an error. (`get_stxos` shipped in
    /// thunder-rust `f98c31ec`, so this op is no longer gated.)
    @Test func historyIsEmptyBeforeSync() throws {
        #expect(try Self.service().transactions(walletId: "w1").isEmpty)
    }

    /// Sync rebuilds history from get_utxos + get_stxos. The spend is only visible because of the
    /// stxo read — the UTXO set alone would show the change and nothing else.
    @Test func syncRebuildsHistoryFromBothReads() async throws {
        let txidIn = String(repeating: "11", count: 32)
        let txidSpend = String(repeating: "22", count: 32)
        let utxos = "[\(Self.utxoJSON(address: Self.address0, sats: 30_000, vout: 0, txid: txidSpend))]"
        let stxos = """
        [{"outpoint":{"Regular":{"txid":"\(txidIn)","vout":0}},
          "output":{"output":{"address":"\(Self.address0)","content":{"Value":100000}},
                    "inpoint":{"Regular":{"txid":"\(txidSpend)","vin":0}}}}]
        """
        let service = Self.service(utxosJSON: utxos, stxosJSON: stxos)
        _ = try await service.sync(walletId: "w1")

        let txs = try service.transactions(walletId: "w1")
        #expect(txs.count == 2)
        #expect(txs.first { $0.txid == txidIn }?.netSats == 100_000)
        #expect(txs.first { $0.txid == txidSpend }?.netSats == -70_000)
    }

    /// A node that doesn't serve get_stxos must still sync and report the right balance — history
    /// degrades to receives-only rather than the whole sync failing.
    @Test func syncSurvivesAGetStxosFailure() async throws {
        let service = Self.service(utxosJSON: "[\(Self.utxoJSON(address: Self.address0, sats: 4_000, vout: 0))]",
                                   stxosFails: true)
        #expect(try await service.sync(walletId: "w1").sats == 4_000)
        #expect(try service.transactions(walletId: "w1").count == 1)
    }

    // MARK: - Sending

    @Test func sendSelectsSignsAndSubmits() async throws {
        let log = RequestLog()
        let service = Self.service(utxosJSON: "[\(Self.utxoJSON(address: Self.address0, sats: 100_000, vout: 0))]",
                                   submitTxid: "beef", requests: log)
        let tx = try await service.send(walletId: "w1", to: Self.address0,
                                        amount: Amount(sats: 25_000), feeRate: FeeRate(satPerVByte: 1))
        #expect(tx.txid == "beef")
        #expect(tx.confirmations == 0)
        #expect(tx.netSats == -(25_000 + (tx.feeSats ?? 0)))

        // The submitted transaction is signed and shaped the way the node expects.
        let submitted = try #require(log.lastParams(method: "submit_transaction") as? [[String: Any]])
        let authorized = submitted[0]
        let transaction = try #require(authorized["transaction"] as? [String: Any])
        let inputs = try #require(transaction["inputs"] as? [[Any]])
        let outputs = try #require(transaction["outputs"] as? [[String: Any]])
        let authorizations = try #require(authorized["authorizations"] as? [[String: Any]])
        #expect(inputs.count == 1)
        #expect(outputs.count == 2)                                    // payment + change
        #expect(authorizations.count == inputs.count)                  // exactly one per input
        #expect((authorizations[0]["signature"] as? String)?.count == 128)   // hex (thunder-rust ≥ 0.18)
        #expect((transaction["proof"] as? [String: Any])?["targets"] as? [Int] == [])
    }

    // MARK: - Withdrawal to the mainchain

    private static let mainAddress = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    private static let mainScript: [UInt8] = ThunderHex.decode("0014751e76e8199196d454941c45d1b3a323f1433bd6")!

    /// Shaped like thunder-rust's `create_withdrawal`: the withdrawal output goes to a FRESH address of
    /// ours, change to another, and the coins cover payout + mainchain fee + sidechain fee.
    @Test func withdrawalBuildsAWithdrawalOutputToAFreshAddressOfOurs() async throws {
        let log = RequestLog()
        let store = InMemoryThunderAddressIndexStore()
        let service = Self.service(utxosJSON: "[\(Self.utxoJSON(address: Self.address0, sats: 100_000, vout: 0))]",
                                   submitTxid: "wd", requests: log, indexStore: store)
        let tx = try await service.withdrawToMainchain(walletId: "w1", mainAddress: Self.mainAddress,
                                                       mainScriptPubKey: Self.mainScript,
                                                       amount: Amount(sats: 40_000), mainFee: Amount(sats: 10_000),
                                                       feeRate: FeeRate(satPerVByte: 1))
        #expect(tx.txid == "wd")
        #expect(tx.netSats == -(40_000 + 10_000 + (tx.feeSats ?? 0)))
        #expect(tx.sidechainWithdrawalAddress == Self.mainAddress)

        let submitted = try #require(log.lastParams(method: "submit_transaction") as? [[String: Any]])
        let transaction = try #require(submitted[0]["transaction"] as? [String: Any])
        let outputs = try #require(transaction["outputs"] as? [[String: Any]])
        #expect(outputs.count == 2)                                       // withdrawal + change
        let withdrawal = try #require((outputs[0]["content"] as? [String: Any])?["Withdrawal"] as? [String: Any])
        #expect(withdrawal["value"] as? Int == 40_000)                    // 0.18 field names
        #expect(withdrawal["main_fee"] as? Int == 10_000)
        #expect(withdrawal["main_address"] as? String == Self.mainAddress)
        // Owner and change are two NEW addresses, neither the one we spent from.
        let owner = outputs[0]["address"] as? String, change = outputs[1]["address"] as? String
        #expect(owner != Self.address0 && change != Self.address0 && owner != change)
        #expect(store.revealedIndex(walletId: "w1") == 2)
    }

    @Test func withdrawalBelowDustOrWithoutAMainchainFeeIsRefusedBeforeSigning() async throws {
        let log = RequestLog()
        let service = Self.service(utxosJSON: "[\(Self.utxoJSON(address: Self.address0, sats: 100_000, vout: 0))]",
                                   requests: log)
        for (amount, mainFee) in [(Int64(545), Int64(10_000)), (Int64(40_000), Int64(0))] {
            do {
                _ = try await service.withdrawToMainchain(walletId: "w1", mainAddress: Self.mainAddress,
                                                          mainScriptPubKey: Self.mainScript,
                                                          amount: Amount(sats: amount), mainFee: Amount(sats: mainFee),
                                                          feeRate: FeeRate(satPerVByte: 1))
                Issue.record("expected withdrawalTooSmall")
            } catch let error as ThunderError {
                #expect(error == .withdrawalTooSmall(minimumSats: 546))
            }
        }
        #expect(log.lastParams(method: "submit_transaction") == nil)
    }

    @Test func withdrawalNeedsCoinsForThePayoutAndItsMainchainFee() async throws {
        // 45,000 covers the 40,000 payout but not payout + 10,000 mainchain fee.
        let service = Self.service(utxosJSON: "[\(Self.utxoJSON(address: Self.address0, sats: 45_000, vout: 0))]")
        do {
            _ = try await service.withdrawToMainchain(walletId: "w1", mainAddress: Self.mainAddress,
                                                      mainScriptPubKey: Self.mainScript,
                                                      amount: Amount(sats: 40_000), mainFee: Amount(sats: 10_000),
                                                      feeRate: FeeRate(satPerVByte: 1))
            Issue.record("expected insufficientFunds")
        } catch let error as ThunderError {
            guard case .insufficientFunds = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func changeGoesToAFreshAddressNotAnInputAddress() async throws {
        let log = RequestLog()
        let store = InMemoryThunderAddressIndexStore()
        let service = Self.service(utxosJSON: "[\(Self.utxoJSON(address: Self.address0, sats: 100_000, vout: 0))]",
                                   requests: log, indexStore: store)
        _ = try await service.send(walletId: "w1", to: Self.address0,
                                   amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1))

        let submitted = try #require(log.lastParams(method: "submit_transaction") as? [[String: Any]])
        let transaction = try #require(submitted[0]["transaction"] as? [String: Any])
        let outputs = try #require(transaction["outputs"] as? [[String: Any]])
        let changeAddress = outputs[1]["address"] as? String
        #expect(changeAddress != Self.address0)                 // not the address we just spent from
        #expect(store.revealedIndex(walletId: "w1") == 1)       // and the counter moved with it
    }

    @Test func sendRejectsABadDestination() async {
        do {
            _ = try await Self.service().send(walletId: "w1", to: "not-an-address",
                                              amount: Amount(sats: 1), feeRate: FeeRate(satPerVByte: 1))
            Issue.record("expected invalidAddress")
        } catch let error as ThunderError {
            #expect(error == .invalidAddress)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func sendWithoutFundsFailsBeforeSigning() async throws {
        let log = RequestLog()
        let service = Self.service(utxosJSON: "[]", requests: log)
        await #expect(throws: ThunderError.self) {
            try await service.send(walletId: "w1", to: Self.address0,
                                   amount: Amount(sats: 5_000), feeRate: FeeRate(satPerVByte: 1))
        }
        #expect(log.lastParams(method: "submit_transaction") == nil)   // nothing was broadcast
    }

    @Test func spentCoinsLeaveTheCacheSoTheyCantBeReselected() async throws {
        let json = "[\(Self.utxoJSON(address: Self.address0, sats: 60_000, vout: 0)),"
            + "\(Self.utxoJSON(address: Self.address0, sats: 60_000, vout: 1))]"
        let service = Self.service(utxosJSON: json)
        _ = try await service.sync(walletId: "w1")
        #expect(try service.balance(walletId: "w1").sats == 120_000)

        _ = try await service.send(walletId: "w1", to: Self.address0,
                                   amount: Amount(sats: 10_000), feeRate: FeeRate(satPerVByte: 1))
        // One 60k coin funded the send, so only the untouched one is still spendable. (The change
        // isn't counted: it doesn't exist in the node's state until the tx is mined.)
        #expect(try service.balance(walletId: "w1").sats == 60_000)
    }

    @Test func sweepDrainsEverythingToOneOutput() async throws {
        let log = RequestLog()
        let json = "[\(Self.utxoJSON(address: Self.address0, sats: 30_000, vout: 0)),"
            + "\(Self.utxoJSON(address: Self.address0, sats: 20_000, vout: 1))]"
        let service = Self.service(utxosJSON: json, requests: log)
        let tx = try await service.sweep(walletId: "w1", to: Self.address0, feeRate: FeeRate(satPerVByte: 1))
        #expect(tx.netSats == -50_000)

        let submitted = try #require(log.lastParams(method: "submit_transaction") as? [[String: Any]])
        let transaction = try #require(submitted[0]["transaction"] as? [String: Any])
        #expect((transaction["inputs"] as? [[Any]])?.count == 2)
        #expect((transaction["outputs"] as? [[String: Any]])?.count == 1)   // no change on a sweep
    }

    @Test func splitIsNotAThingOnThunder() async {
        let service = Self.service()
        // Thunder has no eCash-fork replay exposure, so there is nothing to split — and the zeroed
        // summary is what keeps the split UI hidden for these wallets.
        let summary = try? service.splitSummary(walletId: "w1")
        #expect(summary?.spendableSats == 0)
        #expect(summary?.needsSplitCount == 0)
        do {
            _ = try await service.splitToSelf(walletId: "w1", feeRate: FeeRate(satPerVByte: 1))
            Issue.record("expected unsupportedOperation")
        } catch let error as ThunderError {
            #expect(error == .unsupportedOperation)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

/// Records the JSON-RPC bodies a stubbed client was sent, so tests can assert on what we actually
/// put on the wire.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []

    func append(_ data: Data) { lock.lock(); bodies.append(data); lock.unlock() }

    /// The `params` of the most recent request for `method`, or nil if it was never called.
    func lastParams(method: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        for body in bodies.reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  json["method"] as? String == method else { continue }
            return json["params"]
        }
        return nil
    }
}

/// Counts `loadMnemonic` calls — the watch-only tests assert when the secret is (not) read.
final class MnemonicReads: @unchecked Sendable {
    var count = 0
}
