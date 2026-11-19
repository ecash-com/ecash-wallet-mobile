// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import Crypto
import WalletService
@testable import ECashWalletMobile

// MARK: - Quote signing

@Suite struct FastWithdrawalQuoteTests {

    static func quote(id: String = "w-1", sidechain: String = "thunder", l2Address: String = "L2addr",
                      l2Sats: Int64 = 101_000, destination: String = "bc1qdest", payout: Int64 = 100_000,
                      fee: Int64 = 1_000, confirmations: Int64 = 2, expiresAt: Int64 = 1_760_371_200,
                      status: FastWithdrawalStatus = .awaitingPayment, signature: [UInt8] = []) -> FastWithdrawal {
        FastWithdrawal(id: id, sidechain: sidechain, l2PaymentAddress: l2Address, l2PaymentSats: l2Sats,
                       l1Destination: destination, l1PayoutSats: payout, serviceFeeSats: fee,
                       requiredConfirmations: confirmations, status: status, expiresAt: expiresAt,
                       paymentTxid: "", paymentVout: 0, payoutTxid: "", quoteSignature: signature,
                       l2ReceivedSats: 0, l2RefundAddress: "")
    }

    static func signed(_ q: FastWithdrawal, with key: Curve25519.Signing.PrivateKey) -> FastWithdrawal {
        let signature = [UInt8](try! key.signature(for: Data(FastWithdrawalQuote.signedMessage(q))))
        return quote(id: q.id, sidechain: q.sidechain, l2Address: q.l2PaymentAddress, l2Sats: q.l2PaymentSats,
                     destination: q.l1Destination, payout: q.l1PayoutSats, fee: q.serviceFeeSats,
                     confirmations: q.requiredConfirmations, expiresAt: q.expiresAt, status: q.status,
                     signature: signature)
    }

    static func info(key: [UInt8], bps: Int64 = 100) -> FastWithdrawalServiceInfo {
        FastWithdrawalServiceInfo(quoteSigningPublicKey: key, feeBasisPoints: bps, minimumPayoutSats: 10_000,
                                  maximumPayoutSats: 10_000_000, requiredConfirmations: ["thunder": 2],
                                  hotWalletAddress: "")
    }

    /// The signed bytes, against a vector built independently (Python `struct.pack(">Q", …)`): ten
    /// fields, each prefixed by its 8-byte big-endian length, domain first with its trailing NUL.
    @Test func signedMessageMatchesTheIndependentVector() {
        let hex = FastWithdrawalQuote.signedMessage(Self.quote()).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "00000000000000166661737477697468647261772e71756f74652e7631000000000000000003772d3100000000000000077468756e64657200000000000000064c326164647200000000000000080000000000018a8800000000000000086263317164657374000000000000000800000000000186a0000000000000000800000000000003e80000000000000008000000000000000200000000000000080000000068ed2200")
    }

    @Test func aGenuineSignatureVerifies() {
        let key = Curve25519.Signing.PrivateKey()
        let q = Self.signed(Self.quote(), with: key)
        #expect(FastWithdrawalQuote.signatureIsValid(q, publicKey: [UInt8](key.publicKey.rawRepresentation)))
    }

    /// The property the old Go server lacked: every field is covered, so changing the payout breaks it.
    @Test func changingAnyCoveredFieldBreaksTheSignature() {
        let key = Curve25519.Signing.PrivateKey()
        let pub = [UInt8](key.publicKey.rawRepresentation)
        let good = Self.signed(Self.quote(), with: key)
        let tampered = [
            Self.quote(payout: 1, signature: good.quoteSignature),
            Self.quote(destination: "bc1qattacker", signature: good.quoteSignature),
            Self.quote(l2Address: "attacker", signature: good.quoteSignature),
            Self.quote(l2Sats: 999_999, signature: good.quoteSignature),
            Self.quote(expiresAt: 9_999_999_999, signature: good.quoteSignature),
        ]
        for q in tampered { #expect(!FastWithdrawalQuote.signatureIsValid(q, publicKey: pub)) }
    }

    @Test func aDifferentKeyDoesNotVerify() {
        let q = Self.signed(Self.quote(), with: Curve25519.Signing.PrivateKey())
        let other = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        #expect(!FastWithdrawalQuote.signatureIsValid(q, publicKey: other))
    }

    // MARK: check()

    private func check(_ q: FastWithdrawal, key: Curve25519.Signing.PrivateKey, pinned: [UInt8]? = nil,
                       destination: String = "bc1qdest", payout: Int64 = 100_000,
                       now: Int64 = 1_760_371_200 - 600) throws {
        try FastWithdrawalQuote.check(q, info: Self.info(key: [UInt8](key.publicKey.rawRepresentation)),
                                      pinnedKey: pinned, sidechain: "thunder", l1Destination: destination,
                                      l1PayoutSats: payout, nowSeconds: now)
    }

    @Test func aGoodQuotePasses() throws {
        let key = Curve25519.Signing.PrivateKey()
        try check(Self.signed(Self.quote(), with: key), key: key)
    }

    @Test func aQuoteForSomethingElseIsRejected() {
        let key = Curve25519.Signing.PrivateKey()
        let q = Self.signed(Self.quote(), with: key)
        #expect(throws: FastWithdrawalQuote.Problem.mismatch) { try check(q, key: key, destination: "bc1qother") }
        #expect(throws: FastWithdrawalQuote.Problem.mismatch) { try check(q, key: key, payout: 50_000) }
    }

    @Test func amountsThatDontAddUpAreRejected() {
        let key = Curve25519.Signing.PrivateKey()
        // Signed, but payment ≠ payout + fee.
        let wrongTotal = Self.signed(Self.quote(l2Sats: 150_000), with: key)
        #expect(throws: FastWithdrawalQuote.Problem.badAmounts) { try check(wrongTotal, key: key) }
        // A fee above the advertised 1% (1,000 sats on 100,000).
        let greedy = Self.signed(Self.quote(l2Sats: 105_000, fee: 5_000), with: key)
        #expect(throws: FastWithdrawalQuote.Problem.badAmounts) { try check(greedy, key: key) }
    }

    @Test func aNearlyExpiredQuoteIsNotPaid() {
        let key = Curve25519.Signing.PrivateKey()
        let q = Self.signed(Self.quote(), with: key)
        #expect(throws: FastWithdrawalQuote.Problem.expiring) { try check(q, key: key, now: 1_760_371_200 - 60) }
    }

    @Test func aPinnedKeyMustMatch() throws {
        let key = Curve25519.Signing.PrivateKey()
        let q = Self.signed(Self.quote(), with: key)
        let pinned = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        #expect(throws: FastWithdrawalQuote.Problem.unexpectedKey) { try check(q, key: key, pinned: pinned) }
        try check(q, key: key, pinned: [UInt8](key.publicKey.rawRepresentation))
    }

    @Test func theFeeEstimateRoundsUp() {
        let info = Self.info(key: [], bps: 100)
        #expect(info.estimatedFee(forPayout: 100_000) == 1_000)
        #expect(info.estimatedFee(forPayout: 10_001) == 101)   // 100.01 → 101
        #expect(info.estimatedFee(forPayout: 0) == 0)
    }
}

// MARK: - Wire format

@Suite struct FastWithdrawalClientTests {

    private func client(responding body: String, status: Int = 200) -> FastWithdrawalClient {
        FastWithdrawalClient(baseURL: URL(string: "https://example.test")!) { _ in (Data(body.utf8), status) }
    }

    /// The betanet response of 2026-10-13 with the field names of the published protocol (2026-11):
    /// uint64 as strings, bytes as base64.
    @Test func decodesServiceInfo() async throws {
        let info = try await client(responding: #"{"quoteSigningPublicKey":"UQV+6FfUeQeooadEeQtkAbrpCX1T4lOz+pgYq1iTxo0=","feeBasisPoints":100,"minPayoutSats":"10000","maxPayoutSats":"10000000","sidechains":[{"sidechain":"thunder","requiredConfirmations":2}],"hotWalletAddress":"bc1qwr2ldwlgz6mwdymjkwjrx8nk8dqtup5eupf2yl"}"#).serviceInfo()
        #expect(info.quoteSigningPublicKey.count == 32)
        #expect(info.feeBasisPoints == 100)
        #expect(info.minimumPayoutSats == 10_000)
        #expect(info.maximumPayoutSats == 10_000_000)
        #expect(info.supports(sidechain: "thunder"))
        #expect(!info.supports(sidechain: "bitnames"))
    }

    /// proto3 JSON omits fields at their default value; a fresh quote has no payment yet.
    @Test func decodesAWithdrawalWithOmittedFields() async throws {
        let w = try await client(responding: #"{"withdrawal":{"withdrawalId":"abc","sidechain":"thunder","l2PaymentAddress":"L2","l2PaymentSats":"101000","l1Address":"bc1q","l1PayoutSats":"100000","serviceFeeSats":"1000","requiredConfirmations":2,"status":"WITHDRAWAL_STATUS_AWAITING_PAYMENT","expiresAt":"2026-10-13T16:00:00Z","quoteSignature":"AAEC"}}"#).withdrawal(id: "abc")
        #expect(w.id == "abc")
        #expect(w.l2PaymentSats == 101_000)
        #expect(w.status == .awaitingPayment)
        #expect(w.expiresAt == 1_791_907_200)
        #expect(w.quoteSignature == [0, 1, 2])
        #expect(w.paymentTxid.isEmpty)
        #expect(w.paymentVout == 0)
    }

    /// A REAL quote from the L2L betanet service (2026-10-14), decoded by our client and verified by our
    /// checker against the service's real key. This is the end-to-end proof that the signed-bytes layout
    /// matches the server's. Nothing was ever paid to it; it expired unused. The JSON keys are renamed
    /// to the published protocol's (`l1Address`, `minPayoutSats`, …); the signed VALUES are untouched,
    /// and the published preimage is the same ten fields.
    @Test func aLiveBetanetQuoteVerifies() async throws {
        let info = try await client(responding: #"{"quoteSigningPublicKey":"UQV+6FfUeQeooadEeQtkAbrpCX1T4lOz+pgYq1iTxo0=","feeBasisPoints":100,"minPayoutSats":"10000","maxPayoutSats":"10000000","sidechains":[{"sidechain":"thunder","requiredConfirmations":2}],"hotWalletAddress":"bc1qwr2ldwlgz6mwdymjkwjrx8nk8dqtup5eupf2yl"}"#).serviceInfo()
        let quote = try await client(responding: #"{"withdrawal":{"withdrawalId":"76122db5-664e-4200-b83a-1be66282070a","sidechain":"thunder","l2PaymentAddress":"2CgL244VZBcdUpChyXGcgoLoMiAp","l2PaymentSats":"20200","l1Address":"bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4","l1PayoutSats":"20000","serviceFeeSats":"200","requiredConfirmations":2,"status":"WITHDRAWAL_STATUS_AWAITING_PAYMENT","expiresAt":"2026-10-14T13:58:37Z","quoteSignature":"RuF5tyBKH+clTxLZJhBHQMl1CntD7abPhf+F3RGyDGlR6+utzB/n1UbyDenL/Y+MjfiOZqkl+IB9vGvq4LraCw==","createdAt":"2026-10-14T13:43:37Z","updatedAt":"2026-10-14T13:43:37Z"}}"#).withdrawal(id: "76122db5-664e-4200-b83a-1be66282070a")
        #expect(FastWithdrawalQuote.signatureIsValid(quote, publicKey: info.quoteSigningPublicKey))
        // The full pre-payment check, as of 10 minutes before it expired.
        try FastWithdrawalQuote.check(quote, info: info, pinnedKey: nil, sidechain: "thunder",
                                      l1Destination: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
                                      l1PayoutSats: 20_000, nowSeconds: quote.expiresAt - 600)
        // And a one-sat change to what was signed must fail.
        let tampered = FastWithdrawal(id: quote.id, sidechain: quote.sidechain, l2PaymentAddress: quote.l2PaymentAddress,
                                      l2PaymentSats: quote.l2PaymentSats, l1Destination: quote.l1Destination,
                                      l1PayoutSats: quote.l1PayoutSats - 1, serviceFeeSats: quote.serviceFeeSats,
                                      requiredConfirmations: quote.requiredConfirmations, status: quote.status,
                                      expiresAt: quote.expiresAt, paymentTxid: "", paymentVout: 0, payoutTxid: "",
                                      quoteSignature: quote.quoteSignature, l2ReceivedSats: 0, l2RefundAddress: "")
        #expect(!FastWithdrawalQuote.signatureIsValid(tampered, publicKey: info.quoteSigningPublicKey))
    }

    @Test func decodesAPaidWithdrawal() async throws {
        let w = try await client(responding: #"{"withdrawal":{"withdrawalId":"abc","sidechain":"thunder","l2PaymentAddress":"L2","l2PaymentSats":"101000","l1Address":"bc1q","l1PayoutSats":"100000","serviceFeeSats":"1000","requiredConfirmations":2,"status":"WITHDRAWAL_STATUS_PAID","expiresAt":"2026-10-13T16:00:00Z","l2PaymentTxid":"aa11","l2PaymentVout":3,"l1PayoutTxid":"bb22","quoteSignature":"AAEC"}}"#).withdrawal(id: "abc")
        #expect(w.status == .paid)
        #expect(w.l1Destination == "bc1q")
        #expect(w.paymentTxid == "aa11")
        #expect(w.paymentVout == 3)
        #expect(w.payoutTxid == "bb22")
    }

    @Test func decodesServiceStatus() async throws {
        let open = try await client(responding: #"{"acceptingWithdrawals":true,"maxPayoutNowSats":"2400000","hotWalletBalanceSats":"10000000","dailyCapLeftSats":"50000000","l1TipHeight":973900,"sidechains":[{"sidechain":"thunder","tipHeight":120,"tipBmmHeight":973899,"connectedPeers":4}]}"#).serviceStatus()
        #expect(open.acceptingWithdrawals)
        #expect(open.maxPayoutNowSats == 2_400_000)
        // proto3 JSON omits false and zero.
        let paused = try await client(responding: #"{"pausedReason":"the payout wallet is unavailable"}"#).serviceStatus()
        #expect(!paused.acceptingWithdrawals)
        #expect(paused.pausedReason == "the payout wallet is unavailable")
        #expect(paused.maxPayoutNowSats == 0)
    }

    /// The request bodies use the published field names.
    @Test func requestsUseThePublishedFieldNames() async throws {
        final class Bodies: @unchecked Sendable { var seen: [String: String] = [:] }
        let bodies = Bodies()
        let reply = #"{"withdrawal":{"withdrawalId":"abc","status":"WITHDRAWAL_STATUS_AWAITING_PAYMENT"}}"#
        let client = FastWithdrawalClient(baseURL: URL(string: "https://example.test")!) { request in
            bodies.seen[request.url?.lastPathComponent ?? ""] = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return (Data(reply.utf8), 200)
        }
        _ = try await client.createWithdrawal(requestID: "r", sidechain: "thunder", l1Destination: "bc1q",
                                              l1PayoutSats: 100_000)
        _ = try await client.submitPayment(withdrawalID: "abc", txid: "aa11", vout: 0)
        let create = bodies.seen["CreateWithdrawal"] ?? ""
        #expect(create.contains(#""l1Address":"bc1q""#))
        #expect(create.contains(#""l1PayoutSats":"100000""#))
        #expect(!create.contains("l1Destination"))
        let submit = bodies.seen["SubmitPayment"] ?? ""
        #expect(submit.contains(#""l2PaymentTxid":"aa11""#))
        #expect(submit.contains(#""l2PaymentVout":0"#))
    }

    @Test func serverErrorsCarryTheMessage() async {
        await #expect(throws: CoinNewsError.server(status: 400, message: "payout is outside configured limits")) {
            _ = try await client(responding: #"{"code":"invalid_argument","message":"payout is outside configured limits"}"#,
                                 status: 400).serviceInfo()
        }
    }

    @Test func rfc3339Parsing() {
        #expect(rfc3339Seconds("1970-01-01T00:00:00Z") == 0)
        #expect(rfc3339Seconds("2026-10-13T16:00:00Z") == 1_791_907_200)
        #expect(rfc3339Seconds("2026-10-13T16:00:00.123456Z") == 1_791_907_200)
        #expect(rfc3339Seconds("2026-10-13T16:00:00-04:00") == 1_791_921_600)
        #expect(rfc3339Seconds("2026-10-13 16:00:00") == nil)
        #expect(rfc3339Seconds("nonsense") == nil)
    }
}

// MARK: - View model

@MainActor
@Suite struct FastWithdrawalViewModelTests {

    final class FakeService: FastWithdrawalServicing, @unchecked Sendable {
        let key = Curve25519.Signing.PrivateKey()
        var info: FastWithdrawalServiceInfo
        var quoteOverride: ((FastWithdrawal) -> FastWithdrawal)?
        var remoteStatus: FastWithdrawalStatus = .confirmingPayment
        var created: [(requestID: String, destination: String, payout: Int64)] = []
        var submitted: [(id: String, txid: String, vout: Int32)] = []
        var refunds: [String] = []
        /// nil = the call fails (a service that can't say).
        var status: FastWithdrawalServiceStatus? = FastWithdrawalServiceStatus(
            acceptingWithdrawals: true, pausedReason: "", maxPayoutNowSats: 10_000_000)

        init() {
            info = FastWithdrawalQuoteTests.info(key: [UInt8](key.publicKey.rawRepresentation))
        }

        func serviceInfo() async throws -> FastWithdrawalServiceInfo { info }

        func serviceStatus() async throws -> FastWithdrawalServiceStatus {
            guard let status else { throw CoinNewsError.network }
            return status
        }

        func createWithdrawal(requestID: String, sidechain: String, l1Destination: String,
                              l1PayoutSats: Int64) async throws -> FastWithdrawal {
            created.append((requestID, l1Destination, l1PayoutSats))
            let fee = info.estimatedFee(forPayout: l1PayoutSats)
            var q = FastWithdrawalQuoteTests.quote(id: "w-1", l2Address: "L2pay", l2Sats: l1PayoutSats + fee,
                                                   destination: l1Destination, payout: l1PayoutSats, fee: fee,
                                                   expiresAt: 10_000)
            if let quoteOverride { q = quoteOverride(q) }
            return FastWithdrawalQuoteTests.signed(q, with: key)
        }

        func submitPayment(withdrawalID: String, txid: String, vout: Int32) async throws -> FastWithdrawal {
            submitted.append((withdrawalID, txid, vout))
            return remote(id: withdrawalID, txid: txid)
        }

        func withdrawal(id: String) async throws -> FastWithdrawal { remote(id: id, txid: "") }

        func requestRefund(withdrawalID: String, l2RefundAddress: String) async throws -> FastWithdrawal {
            refunds.append(l2RefundAddress)
            return remote(id: withdrawalID, txid: "")
        }

        private func remote(id: String, txid: String) -> FastWithdrawal {
            FastWithdrawal(id: id, sidechain: "thunder", l2PaymentAddress: "L2pay", l2PaymentSats: 0,
                           l1Destination: "", l1PayoutSats: 0, serviceFeeSats: 0, requiredConfirmations: 2,
                           status: remoteStatus, expiresAt: 10_000, paymentTxid: txid, paymentVout: 0,
                           payoutTxid: remoteStatus == .paid ? "payout-txid" : "", quoteSignature: [],
                           l2ReceivedSats: 0, l2RefundAddress: "")
        }
    }

    final class Calls: @unchecked Sendable {
        var payments: [(address: String, sats: Int64)] = []
        /// What the store held at the moment of payment — proves the record was saved FIRST.
        var recordAtPayment: FastWithdrawalRecord?
        var paid: [WalletTx] = []
    }

    private static let destination = "bc1qdest"

    private func makeVM(service: FakeService, calls: Calls, store: FastWithdrawalStore,
                        payError: Error? = nil, approve: Bool = true,
                        resuming: FastWithdrawalRecord? = nil) -> FastWithdrawalViewModel {
        let deps = FastWithdrawalViewModel.Dependencies(
            service: service,
            endpoint: .init(baseURL: URL(string: "https://example.test"), sidechainID: "thunder",
                            operatorName: "L2L", pinnedQuoteKeyBase64: nil),
            isValidDestination: { $0 == Self.destination },
            pay: { address, amount in
                calls.recordAtPayment = store.record(id: "w-1", walletId: "wallet")
                if let payError { throw payError }
                calls.payments.append((address, amount.sats))
                return WalletTx(txid: "pay-txid", netSats: -amount.sats, feeSats: nil,
                                confirmations: Int32(0), timestampEpochSeconds: nil, isRBF: false)
            },
            authorize: { _ in approve },
            refundAddress: { "refund-addr" },
            addressForDestination: { _ in Self.destination },
            onPaid: { calls.paid.append($0) },
            store: store,
            now: { 9_000 },
            newRequestID: { "req-\(service.created.count)" })
        return FastWithdrawalViewModel(
            walletId: "wallet", sidechainTitle: "Thunder", sidechainNetwork: .thunder,
            mainchain: .ecashBeta, mainchainDisplayName: "Betanet", unitLabel: "ECX",
            spendable: Amount(sats: 1_000_000), destinations: [], resuming: resuming, dependencies: deps)
    }

    private func freshStore() -> FastWithdrawalStore {
        FastWithdrawalStore(defaults: UserDefaults(suiteName: "fastwithdraw-test-\(UUID().uuidString)")!)
    }

    private func reachReview(_ vm: FastWithdrawalViewModel) async {
        await vm.loadIfNeeded()
        vm.addressText = Self.destination
        vm.amountText = "0.001"   // 100,000 sats
        await vm.requestQuote()
    }

    @Test func aVerifiedQuoteReachesReview() async {
        let service = FakeService()
        let vm = makeVM(service: service, calls: Calls(), store: freshStore())
        await reachReview(vm)
        #expect(vm.quote?.l1PayoutSats == 100_000)
        #expect(vm.quote?.l2PaymentSats == 101_000)
        #expect(service.created.first?.destination == Self.destination)
    }

    @Test func aTamperedQuoteIsNeverPaid() async {
        let service = FakeService()
        // The service signs a quote paying out less than asked.
        service.quoteOverride = { q in FastWithdrawalQuoteTests.quote(l2Address: q.l2PaymentAddress, l2Sats: 51_000,
                                                                      destination: q.l1Destination, payout: 50_000,
                                                                      fee: 1_000, expiresAt: q.expiresAt) }
        let calls = Calls()
        let vm = makeVM(service: service, calls: calls, store: freshStore())
        await reachReview(vm)
        #expect(vm.quote == nil)
        if case .failed = vm.phase {} else { Issue.record("expected failure, got \(vm.phase)") }
        #expect(calls.payments.isEmpty)
    }

    @Test func theRecordIsSavedBeforeThePayment() async {
        let service = FakeService()
        let calls = Calls()
        let store = freshStore()
        let vm = makeVM(service: service, calls: calls, store: store)
        await reachReview(vm)
        vm.acknowledged = true
        await vm.confirm()

        #expect(calls.recordAtPayment?.paymentStarted == true)          // saved before broadcast
        #expect(calls.payments.first?.address == "L2pay")
        #expect(calls.payments.first?.sats == 101_000)                  // exactly the quote, once
        #expect(calls.payments.count == 1)
        #expect(service.submitted.first?.txid == "pay-txid")
        #expect(service.submitted.first?.vout == 0)
        #expect(vm.phase == .tracking)
        #expect(store.record(id: "w-1", walletId: "wallet")?.paymentTxid == "pay-txid")
        #expect(store.activeRecords(walletId: "wallet").count == 1)
    }

    @Test func confirmingNeedsTheAcknowledgement() async {
        let calls = Calls()
        let vm = makeVM(service: FakeService(), calls: calls, store: freshStore())
        await reachReview(vm)
        await vm.confirm()
        #expect(calls.payments.isEmpty)
    }

    @Test func aDeniedAuthPaysNothing() async {
        let calls = Calls()
        let vm = makeVM(service: FakeService(), calls: calls, store: freshStore(), approve: false)
        await reachReview(vm)
        vm.acknowledged = true
        await vm.confirm()
        #expect(calls.payments.isEmpty)
        #expect(vm.quote != nil)
    }

    /// Nothing left the wallet: the record is dropped and the user can fix it.
    @Test func aPaymentRefusedBeforeBroadcastIsForgotten() async {
        let store = freshStore()
        let vm = makeVM(service: FakeService(), calls: Calls(), store: store,
                        payError: ThunderError.insufficientFunds(neededSats: 101_000, availableSats: 5))
        await reachReview(vm)
        vm.acknowledged = true
        await vm.confirm()
        if case .failed = vm.phase {} else { Issue.record("expected failure, got \(vm.phase)") }
        #expect(store.activeRecords(walletId: "wallet").isEmpty)
    }

    /// It may have gone out: never offer to pay again; keep tracking.
    @Test func anUnclearPaymentKeepsTracking() async {
        struct Boom: Error {}
        let store = freshStore()
        let vm = makeVM(service: FakeService(), calls: Calls(), store: store, payError: Boom())
        await reachReview(vm)
        vm.acknowledged = true
        await vm.confirm()
        #expect(vm.phase == .tracking)
        #expect(vm.paymentNotice != nil)
        #expect(store.activeRecords(walletId: "wallet").count == 1)
    }

    @Test func trackingStopsWhenPaid() async {
        let service = FakeService()
        service.remoteStatus = .paid
        let store = freshStore()
        let vm = makeVM(service: service, calls: Calls(), store: store)
        await reachReview(vm)
        vm.acknowledged = true
        await vm.confirm()
        await vm.track()
        #expect(vm.record?.status == .paid)
        #expect(vm.record?.payoutTxid == "payout-txid")
        #expect(store.activeRecords(walletId: "wallet").isEmpty)   // settled → no longer active
    }

    @Test func anUnderpaymentRefundsToThisWallet() async {
        let service = FakeService()
        service.remoteStatus = .underpaid
        let resumed = FastWithdrawalRecord(
            id: "w-1", walletId: "wallet", requestID: "r", sidechain: "thunder", l1Destination: Self.destination,
            l1PayoutSats: 100_000, l2PaymentAddress: "L2pay", l2PaymentSats: 101_000, serviceFeeSats: 1_000,
            expiresAt: 10_000, createdAt: 1, paymentTxid: "pay-txid", paymentStarted: true, status: .underpaid,
            payoutTxid: nil, l2ReceivedSats: 50_000, l2RefundAddress: nil, dismissed: false)
        let vm = makeVM(service: service, calls: Calls(), store: freshStore(), resuming: resumed)
        #expect(vm.phase == .tracking)
        await vm.requestRefund()
        #expect(service.refunds == ["refund-addr"])
        #expect(vm.record?.l2RefundAddress == "refund-addr")
        await vm.requestRefund()   // one-shot
        #expect(service.refunds.count == 1)
    }

    @Test func limitsComeFromTheService() async {
        let vm = makeVM(service: FakeService(), calls: Calls(), store: freshStore())
        await vm.loadIfNeeded()
        vm.addressText = Self.destination
        vm.amountText = "0.00005"   // 5,000 < 10,000 minimum
        #expect(vm.amountProblem == .belowMinimum)
        #expect(!vm.canQuote)
        vm.amountText = "0.2"       // 20,000,000 > 10,000,000 maximum
        #expect(vm.amountProblem == .aboveMaximum)
    }

    @Test func aPausedServiceIsUnavailable() async {
        let service = FakeService()
        service.status = FastWithdrawalServiceStatus(acceptingWithdrawals: false,
                                                     pausedReason: "the payout wallet is unavailable",
                                                     maxPayoutNowSats: 0)
        let vm = makeVM(service: service, calls: Calls(), store: freshStore())
        await vm.loadIfNeeded()
        if case .unavailable(let message) = vm.phase {
            #expect(message.contains("the payout wallet is unavailable"))
        } else { Issue.record("expected unavailable, got \(vm.phase)") }
    }

    /// The hot wallet can fund less than the configured cap: the lower number is the limit shown.
    @Test func theMaximumFollowsWhatTheServiceCanFundNow() async {
        let service = FakeService()
        service.status = FastWithdrawalServiceStatus(acceptingWithdrawals: true, pausedReason: "",
                                                     maxPayoutNowSats: 50_000)
        let vm = makeVM(service: service, calls: Calls(), store: freshStore())
        await vm.loadIfNeeded()
        vm.addressText = Self.destination
        #expect(vm.maximum?.sats == 50_000)
        vm.amountText = "0.001"   // 100,000 > 50,000
        #expect(vm.amountProblem == .aboveMaximum)
        vm.amountText = "0.0004"
        #expect(vm.amountProblem == .none)
    }

    @Test func aStatusFailureDoesNotBlockTheFlow() async {
        let service = FakeService()
        service.status = nil
        let vm = makeVM(service: service, calls: Calls(), store: freshStore())
        await vm.loadIfNeeded()
        #expect(vm.phase == .entering)
        #expect(vm.maximum?.sats == 10_000_000)
    }

    /// A record saved by a build that knew the dropped PAYOUT_PREPARED status still loads.
    @Test func aRecordWithTheDroppedStatusStillLoads() {
        let store = freshStore()
        store.save(FastWithdrawalRecord(
            id: "w-1", walletId: "wallet", requestID: "r", sidechain: "thunder", l1Destination: "d",
            l1PayoutSats: 1, l2PaymentAddress: "a", l2PaymentSats: 2, serviceFeeSats: 1, expiresAt: 1,
            createdAt: 1, paymentTxid: "t", paymentStarted: true, status: .payoutPrepared,
            payoutTxid: nil, l2ReceivedSats: 0, l2RefundAddress: nil, dismissed: false))
        #expect(store.activeRecords(walletId: "wallet").first?.status == .payoutPrepared)
    }

    @Test func removingAWalletForgetsItsWithdrawals() {
        let store = freshStore()
        let record = FastWithdrawalRecord(
            id: "w-1", walletId: "wallet", requestID: "r", sidechain: "thunder", l1Destination: "d",
            l1PayoutSats: 1, l2PaymentAddress: "a", l2PaymentSats: 2, serviceFeeSats: 1, expiresAt: 1,
            createdAt: 1, paymentTxid: nil, paymentStarted: true, status: .confirmingPayment,
            payoutTxid: nil, l2ReceivedSats: 0, l2RefundAddress: nil, dismissed: false)
        store.save(record)
        #expect(store.records(walletId: "wallet").count == 1)
        store.forget(walletId: "wallet")
        #expect(store.records(walletId: "wallet").isEmpty)
    }
}
