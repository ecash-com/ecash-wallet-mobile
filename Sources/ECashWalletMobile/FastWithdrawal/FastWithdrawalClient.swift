// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The fast-withdrawal service's six calls (`fastwithdraw.v1.FastWithdrawalService`, schema in
/// github.com/LayerTwo-Labs/fast-withdrawals `proto/fastwithdraw/v1/fastwithdraw.proto`). A protocol so
/// the view model is tested against a fake.
protocol FastWithdrawalServicing: Sendable {
    func serviceInfo() async throws -> FastWithdrawalServiceInfo
    /// Whether withdrawals are accepted right now, and how large one can be.
    func serviceStatus() async throws -> FastWithdrawalServiceStatus
    func createWithdrawal(requestID: String, sidechain: String, l1Destination: String,
                          l1PayoutSats: Int64) async throws -> FastWithdrawal
    func submitPayment(withdrawalID: String, txid: String, vout: Int32) async throws -> FastWithdrawal
    func withdrawal(id: String) async throws -> FastWithdrawal
    func requestRefund(withdrawalID: String, l2RefundAddress: String) async throws -> FastWithdrawal
}

/// Connect over HTTP/JSON, through the same `ConnectRPCClient` CoinNews uses. Its errors are
/// `CoinNewsError` (the name predates this second user); `.server` carries the service's message.
struct FastWithdrawalClient: FastWithdrawalServicing {
    static let service = "fastwithdraw.v1.FastWithdrawalService"
    private let rpc: ConnectRPCClient

    init(baseURL: URL, fetch: @escaping ConnectRPCClient.Fetch = ConnectRPCClient.defaultFetch) {
        rpc = ConnectRPCClient(baseURL: baseURL, fetch: fetch)
    }

    func serviceInfo() async throws -> FastWithdrawalServiceInfo {
        let dto: ServiceInfoDTO = try await rpc.unary(service: Self.service, method: "GetServiceInfo",
                                                      request: EmptyRequest())
        return dto.model
    }

    func serviceStatus() async throws -> FastWithdrawalServiceStatus {
        let dto: ServiceStatusDTO = try await rpc.unary(service: Self.service, method: "GetStatus",
                                                        request: EmptyRequest())
        return dto.model
    }

    func createWithdrawal(requestID: String, sidechain: String, l1Destination: String,
                          l1PayoutSats: Int64) async throws -> FastWithdrawal {
        let request = CreateRequest(requestId: requestID, sidechain: sidechain, l1Address: l1Destination,
                                    l1PayoutSats: String(l1PayoutSats))
        let dto: WithdrawalEnvelope = try await rpc.unary(service: Self.service, method: "CreateWithdrawal",
                                                          request: request)
        return try dto.model()
    }

    func submitPayment(withdrawalID: String, txid: String, vout: Int32) async throws -> FastWithdrawal {
        let request = SubmitRequest(withdrawalId: withdrawalID, l2PaymentTxid: txid, l2PaymentVout: vout)
        let dto: WithdrawalEnvelope = try await rpc.unary(service: Self.service, method: "SubmitPayment",
                                                          request: request)
        return try dto.model()
    }

    func withdrawal(id: String) async throws -> FastWithdrawal {
        let dto: WithdrawalEnvelope = try await rpc.unary(service: Self.service, method: "GetWithdrawal",
                                                          request: GetRequest(withdrawalId: id))
        return try dto.model()
    }

    func requestRefund(withdrawalID: String, l2RefundAddress: String) async throws -> FastWithdrawal {
        let request = RefundRequest(withdrawalId: withdrawalID, l2RefundAddress: l2RefundAddress)
        let dto: WithdrawalEnvelope = try await rpc.unary(service: Self.service, method: "RequestRefund",
                                                          request: request)
        return try dto.model()
    }
}

// MARK: - Models

/// `GetStatus`: the service's state right now, as opposed to `GetServiceInfo`'s fixed terms.
struct FastWithdrawalServiceStatus: Equatable, Sendable {
    let acceptingWithdrawals: Bool
    /// Why not, when `acceptingWithdrawals` is false. The service's own wording.
    let pausedReason: String
    /// The largest payout a quote can ask for right now (liquidity and daily cap). Zero while paused.
    let maxPayoutNowSats: Int64
}

struct FastWithdrawalServiceInfo: Equatable, Sendable {
    let quoteSigningPublicKey: [UInt8]
    let feeBasisPoints: Int64
    let minimumPayoutSats: Int64
    let maximumPayoutSats: Int64
    /// Required confirmations per sidechain id ("thunder" → 2).
    let requiredConfirmations: [String: Int64]
    /// Payouts come from here; empty while the operator's wallet is unreachable.
    let hotWalletAddress: String

    func supports(sidechain: String) -> Bool { requiredConfirmations[sidechain] != nil }

    /// The fee the service will charge for `payoutSats`, rounded UP as the service does. An estimate
    /// for the entry screen only — the quote's own `serviceFeeSats` is the truth.
    func estimatedFee(forPayout payoutSats: Int64) -> Int64 {
        guard payoutSats > 0, feeBasisPoints > 0 else { return 0 }
        let product = payoutSats.multipliedReportingOverflow(by: feeBasisPoints)
        guard !product.overflow else { return Int64.max }
        return (product.partialValue + 9_999) / 10_000
    }
}

enum FastWithdrawalStatus: String, Codable, Equatable, Sendable {
    case unspecified = "WITHDRAWAL_STATUS_UNSPECIFIED"
    case awaitingPayment = "WITHDRAWAL_STATUS_AWAITING_PAYMENT"
    case confirmingPayment = "WITHDRAWAL_STATUS_CONFIRMING_PAYMENT"
    case paymentConfirmed = "WITHDRAWAL_STATUS_PAYMENT_CONFIRMED"
    /// No longer sent by the service (dropped from the protocol, 2026-11). Kept so a record saved by
    /// an older build still decodes; treated as `paymentConfirmed`.
    case payoutPrepared = "WITHDRAWAL_STATUS_PAYOUT_PREPARED"
    case paid = "WITHDRAWAL_STATUS_PAID"
    case expired = "WITHDRAWAL_STATUS_EXPIRED"
    case failed = "WITHDRAWAL_STATUS_FAILED"
    case underpaid = "WITHDRAWAL_STATUS_UNDERPAID"
    case refunded = "WITHDRAWAL_STATUS_REFUNDED"

    /// Nothing more will happen without someone acting. `.expired` isn't here: a payment to an expired
    /// quote is still honored, so an expired quote we've already paid keeps being polled.
    var isFinal: Bool { self == .paid || self == .failed || self == .refunded }
}

/// One withdrawal as the service reports it. Amounts are signed `Int64` (the app's money type).
/// On the wire `l1Destination` is `l1_address`, `paymentTxid`/`paymentVout` are `l2_payment_txid`/
/// `l2_payment_vout` and `payoutTxid` is `l1_payout_txid` (renamed in the protocol, 2026-11); the
/// names here are unchanged because saved records use them.
struct FastWithdrawal: Equatable, Sendable {
    let id: String
    let sidechain: String
    let l2PaymentAddress: String
    let l2PaymentSats: Int64
    let l1Destination: String
    let l1PayoutSats: Int64
    let serviceFeeSats: Int64
    let requiredConfirmations: Int64
    let status: FastWithdrawalStatus
    /// Unix seconds — the value the quote signature covers.
    let expiresAt: Int64
    let paymentTxid: String
    let paymentVout: Int32
    let payoutTxid: String
    let quoteSignature: [UInt8]
    let l2ReceivedSats: Int64
    let l2RefundAddress: String
}

// MARK: - proto3 JSON
//
// lowerCamelCase keys; uint64 as STRINGS; uint32 as numbers; bytes as base64; Timestamp as an RFC 3339
// string; enums by name. Fields at their default value may be omitted entirely, so everything decodes
// as optional and defaults here.

private struct ServiceInfoDTO: Decodable {
    let quoteSigningPublicKey: String?
    let feeBasisPoints: Int64?
    let minPayoutSats: String?
    let maxPayoutSats: String?
    let sidechains: [ChainPolicyDTO]?
    let hotWalletAddress: String?

    var model: FastWithdrawalServiceInfo {
        var confirmations: [String: Int64] = [:]
        for chain in sidechains ?? [] {
            if let id = chain.sidechain, !id.isEmpty { confirmations[id] = chain.requiredConfirmations ?? 0 }
        }
        return FastWithdrawalServiceInfo(
            quoteSigningPublicKey: base64Bytes(quoteSigningPublicKey),
            feeBasisPoints: feeBasisPoints ?? 0,
            minimumPayoutSats: Int64(minPayoutSats ?? "") ?? 0,
            maximumPayoutSats: Int64(maxPayoutSats ?? "") ?? 0,
            requiredConfirmations: confirmations,
            hotWalletAddress: hotWalletAddress ?? "")
    }
}

private struct ServiceStatusDTO: Decodable {
    let acceptingWithdrawals: Bool?
    let pausedReason: String?
    let maxPayoutNowSats: String?

    var model: FastWithdrawalServiceStatus {
        FastWithdrawalServiceStatus(acceptingWithdrawals: acceptingWithdrawals ?? false,
                                    pausedReason: pausedReason ?? "",
                                    maxPayoutNowSats: Int64(maxPayoutNowSats ?? "") ?? 0)
    }
}

private struct ChainPolicyDTO: Decodable {
    let sidechain: String?
    let requiredConfirmations: Int64?
}

private struct WithdrawalEnvelope: Decodable {
    let withdrawal: WithdrawalDTO?

    func model() throws -> FastWithdrawal {
        guard let withdrawal, let id = withdrawal.withdrawalId, !id.isEmpty else {
            throw CoinNewsError.decode("response has no withdrawal")
        }
        return try withdrawal.model(id: id)
    }
}

private struct WithdrawalDTO: Decodable {
    let withdrawalId: String?
    let sidechain: String?
    let l2PaymentAddress: String?
    let l2PaymentSats: String?
    let l1Address: String?
    let l1PayoutSats: String?
    let serviceFeeSats: String?
    let requiredConfirmations: Int64?
    let status: String?
    let expiresAt: String?
    let l2PaymentTxid: String?
    let l2PaymentVout: Int32?
    let l1PayoutTxid: String?
    let quoteSignature: String?
    let l2ReceivedSats: String?
    let l2RefundAddress: String?

    func model(id: String) throws -> FastWithdrawal {
        guard let status = FastWithdrawalStatus(rawValue: status ?? FastWithdrawalStatus.unspecified.rawValue) else {
            throw CoinNewsError.decode("unknown withdrawal status")
        }
        return FastWithdrawal(
            id: id,
            sidechain: sidechain ?? "",
            l2PaymentAddress: l2PaymentAddress ?? "",
            l2PaymentSats: Int64(l2PaymentSats ?? "") ?? 0,
            l1Destination: l1Address ?? "",
            l1PayoutSats: Int64(l1PayoutSats ?? "") ?? 0,
            serviceFeeSats: Int64(serviceFeeSats ?? "") ?? 0,
            requiredConfirmations: requiredConfirmations ?? 0,
            status: status,
            expiresAt: expiresAt.flatMap(rfc3339Seconds) ?? 0,
            paymentTxid: l2PaymentTxid ?? "",
            paymentVout: l2PaymentVout ?? 0,
            payoutTxid: l1PayoutTxid ?? "",
            quoteSignature: base64Bytes(quoteSignature),
            l2ReceivedSats: Int64(l2ReceivedSats ?? "") ?? 0,
            l2RefundAddress: l2RefundAddress ?? "")
    }
}

private struct CreateRequest: Encodable {
    let requestId: String
    let sidechain: String
    let l1Address: String
    let l1PayoutSats: String   // uint64 → string in proto3 JSON
}

private struct SubmitRequest: Encodable {
    let withdrawalId: String
    let l2PaymentTxid: String
    let l2PaymentVout: Int32
}

private struct GetRequest: Encodable {
    let withdrawalId: String
}

private struct RefundRequest: Encodable {
    let withdrawalId: String
    let l2RefundAddress: String
}

private func base64Bytes(_ string: String?) -> [UInt8] {
    guard let string, let data = Data(base64Encoded: string) else { return [] }
    return [UInt8](data)
}

/// Whole Unix seconds from an RFC 3339 timestamp ("2026-10-13T16:00:00Z", optionally with a fraction
/// and a numeric offset). Parsed by hand: it's the exact value the quote signature covers, so it must
/// not depend on a date formatter's platform quirks, and the fraction is dropped (the service signs
/// whole seconds).
func rfc3339Seconds(_ text: String) -> Int64? {
    let chars = Array(text)
    func number(_ from: Int, _ count: Int) -> Int64? {
        guard from + count <= chars.count else { return nil }
        var value: Int64 = 0
        for c in chars[from..<(from + count)] {
            guard let d = c.wholeNumberValue else { return nil }
            value = value * 10 + Int64(d)
        }
        return value
    }
    guard chars.count >= 20, chars[4] == "-", chars[7] == "-", chars[10] == "T" || chars[10] == "t",
          chars[13] == ":", chars[16] == ":",
          let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
          let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
          (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
    else { return nil }

    var index = 19
    if index < chars.count, chars[index] == "." {
        index += 1
        while index < chars.count, chars[index].wholeNumberValue != nil { index += 1 }
    }
    guard index < chars.count else { return nil }
    var offsetSeconds: Int64 = 0
    switch chars[index] {
    case "Z", "z":
        guard index + 1 == chars.count else { return nil }
    case "+", "-":
        guard index + 6 == chars.count, chars[index + 3] == ":",
              let oh = number(index + 1, 2), let om = number(index + 4, 2) else { return nil }
        offsetSeconds = (oh * 3600 + om * 60) * (chars[index] == "+" ? 1 : -1)
    default:
        return nil
    }

    // Days since 1970-01-01 (proleptic Gregorian), Howard Hinnant's days_from_civil.
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
}
