// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives a fast withdrawal from a sidechain wallet to its mainchain through a liquidity provider
/// (`docs/fast-withdrawal.md`): destination + amount → quote (verified) → review → device auth →
/// record saved → pay on the sidechain → track until paid out.
///
/// Custodial and not atomic: the user pays first and trusts the operator. So the order is strict —
/// the quote is verified before anything moves, the record is saved BEFORE the payment is broadcast,
/// and a payment whose outcome is unclear is never offered again (the service finds payments on its
/// own once mined; polling resolves it).
@MainActor
@Observable
final class FastWithdrawalViewModel {
    enum Phase: Equatable {
        case loading
        case unavailable(String)
        case entering
        case quoting
        case reviewing(FastWithdrawal)
        case paying
        case tracking
        case failed(String)   // before any payment — safe to start over
    }

    struct Dependencies {
        var service: FastWithdrawalServicing
        var endpoint: FastWithdrawalConfig.Endpoint
        /// True when `address` is valid ON THE MAINCHAIN (checked by BDK).
        var isValidDestination: (String) -> Bool
        /// Pay `amount` to the quote's sidechain address in ONE output (output 0). Throws before
        /// broadcasting for problems like insufficient funds.
        var pay: (_ address: String, _ amount: Amount) async throws -> WalletTx
        var authorize: (String) async -> Bool
        /// A fresh address of THIS wallet, for an underpayment refund.
        var refundAddress: () async throws -> String
        var addressForDestination: (String) async throws -> String
        var onPaid: @MainActor (WalletTx) -> Void
        var store: FastWithdrawalStore
        var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
        var newRequestID: () -> String = { UUID().uuidString.lowercased() }
    }

    let walletId: String
    let sidechainTitle: String
    let sidechainNetwork: WalletNetwork
    let mainchain: WalletNetwork
    let mainchainDisplayName: String
    let unitLabel: String
    let spendable: Amount
    let destinations: [SendViewModel.Destination]
    var operatorName: String { deps.endpoint.operatorName }

    private(set) var phase: Phase = .loading
    private(set) var info: FastWithdrawalServiceInfo?
    /// The largest payout the service can fund right now (`GetStatus`), when it said. Below the
    /// configured maximum while its hot wallet is low or near its daily cap.
    private(set) var maxPayoutNowSats: Int64?
    private(set) var record: FastWithdrawalRecord?
    private(set) var authorizing = false
    private(set) var isResolvingDestination = false
    private(set) var destinationError: String?
    private(set) var isRequestingRefund = false
    private(set) var refundError: String?
    /// After a payment whose broadcast we couldn't confirm: shown on the tracking view.
    private(set) var paymentNotice: String?

    var addressText = ""
    var amountText = ""
    /// "I understand I'm trusting the operator" — required to confirm.
    var acknowledged = false

    private let deps: Dependencies
    /// Reused while the destination and amount are unchanged, so a retried quote request returns the
    /// SAME quote instead of a second one.
    private var requestID: String?
    private var requestKey: String?

    init(walletId: String, sidechainTitle: String, sidechainNetwork: WalletNetwork,
         mainchain: WalletNetwork, mainchainDisplayName: String, unitLabel: String,
         spendable: Amount, destinations: [SendViewModel.Destination],
         resuming: FastWithdrawalRecord? = nil, dependencies: Dependencies) {
        self.walletId = walletId
        self.sidechainTitle = sidechainTitle
        self.sidechainNetwork = sidechainNetwork
        self.mainchain = mainchain
        self.mainchainDisplayName = mainchainDisplayName
        self.unitLabel = unitLabel
        self.spendable = spendable
        self.destinations = destinations
        self.deps = dependencies
        if let resuming {
            record = resuming
            phase = .tracking
        }
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        guard phase == .loading else { return }
        do {
            let info = try await deps.service.serviceInfo()
            guard info.supports(sidechain: deps.endpoint.sidechainID) else {
                phase = .unavailable("Fast withdrawal isn't available for \(sidechainTitle) right now.")
                return
            }
            // Best effort: a service that can't answer this still refuses a quote it can't fund.
            if let status = try? await deps.service.serviceStatus() {
                guard status.acceptingWithdrawals else {
                    phase = .unavailable(status.pausedReason.isEmpty
                        ? "The provider isn't taking fast withdrawals right now. Try again later."
                        : "The provider isn't taking fast withdrawals right now: \(status.pausedReason)")
                    return
                }
                if status.maxPayoutNowSats > 0 { maxPayoutNowSats = status.maxPayoutNowSats }
            }
            self.info = info
            phase = .entering
        } catch {
            phase = .unavailable(Self.message(for: error))
        }
    }

    func retryLoading() async {
        if case .unavailable = phase { phase = .loading }
        await loadIfNeeded()
    }

    // MARK: - Entering

    var hasDestinations: Bool { !destinations.isEmpty }

    func useDestination(_ destination: SendViewModel.Destination) async {
        guard !isResolvingDestination else { return }
        isResolvingDestination = true
        destinationError = nil
        defer { isResolvingDestination = false }
        do {
            let address = try await deps.addressForDestination(destination.id)
            guard !address.isEmpty else {
                destinationError = "Couldn't get an address from \(destination.label)."
                return
            }
            addressText = address
        } catch {
            destinationError = "Couldn't get an address from \(destination.label)."
        }
    }

    var trimmedAddress: String { addressText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isAddressValid: Bool { !trimmedAddress.isEmpty && deps.isValidDestination(trimmedAddress) }
    var isAddressInvalid: Bool { !trimmedAddress.isEmpty && !deps.isValidDestination(trimmedAddress) }

    var amount: Amount? { Amount.fromCoin(amountText) }
    var minimum: Amount? { info.map { Amount(sats: $0.minimumPayoutSats) } }
    /// The configured cap, or what the service can fund right now when that's less.
    var maximumSats: Int64? {
        guard let info else { return nil }
        return min(info.maximumPayoutSats, maxPayoutNowSats ?? info.maximumPayoutSats)
    }
    var maximum: Amount? { maximumSats.map { Amount(sats: $0) } }
    /// Fee estimate from the advertised rate. The quote's own fee is the truth.
    var estimatedFee: Amount? {
        guard let info, let amount else { return nil }
        return Amount(sats: info.estimatedFee(forPayout: amount.sats))
    }
    var feePercentText: String {
        guard let bps = info?.feeBasisPoints else { return "" }
        let whole = bps / 100, fraction = bps % 100
        return fraction == 0 ? "\(whole)%" : "\(whole).\(fraction < 10 ? "0" : "")\(fraction)%"
    }

    enum AmountProblem: Equatable { case none, belowMinimum, aboveMaximum, exceedsBalance }

    var amountProblem: AmountProblem {
        guard let amount, let info else { return .none }
        if amount.sats < info.minimumPayoutSats { return .belowMinimum }
        if amount.sats > maximumSats ?? info.maximumPayoutSats { return .aboveMaximum }
        let fee = info.estimatedFee(forPayout: amount.sats)
        return amount.sats + fee > spendable.sats ? .exceedsBalance : .none
    }

    var canQuote: Bool {
        guard phase == .entering, isAddressValid, let amount, amount.sats > 0 else { return false }
        return amountProblem == .none
    }

    /// Ask for a quote and verify it. Nothing has moved yet, so any failure is harmless.
    func requestQuote() async {
        guard canQuote, let info, let amount else { return }
        let destination = trimmedAddress
        let key = "\(destination)|\(amount.sats)"
        if requestKey != key { requestID = deps.newRequestID(); requestKey = key }
        guard let requestID else { return }
        phase = .quoting
        do {
            let quote = try await deps.service.createWithdrawal(
                requestID: requestID, sidechain: deps.endpoint.sidechainID,
                l1Destination: destination, l1PayoutSats: amount.sats)
            try FastWithdrawalQuote.check(quote, info: info, pinnedKey: pinnedKey,
                                          sidechain: deps.endpoint.sidechainID,
                                          l1Destination: destination, l1PayoutSats: amount.sats,
                                          nowSeconds: deps.now())
            acknowledged = false
            phase = .reviewing(quote)
        } catch let problem as FastWithdrawalQuote.Problem {
            // A quote that doesn't check out is never paid. A fresh request id next time, so a retry
            // can't hand back the same bad quote.
            requestKey = nil
            phase = .failed(Self.message(for: problem))
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private var pinnedKey: [UInt8]? {
        deps.endpoint.pinnedQuoteKeyBase64.flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) }
    }

    func back() {
        if case .reviewing = phase { phase = .entering }
        if case .failed = phase { phase = .entering }
    }

    // MARK: - Confirming

    var quote: FastWithdrawal? {
        if case .reviewing(let quote) = phase { return quote }
        return nil
    }

    var secondsLeft: Int64? { quote.map { max(0, $0.expiresAt - deps.now()) } }

    var isBusy: Bool { phase == .paying || phase == .quoting || authorizing }
    var canConfirm: Bool { quote != nil && acknowledged && !isBusy }

    func confirm() async {
        guard canConfirm, let quote else { return }
        authorizing = true
        let approved = await deps.authorize("Authorize fast withdrawal to \(mainchainDisplayName)")
        authorizing = false
        guard approved else { return }
        // Re-check the clock: the user may have sat on the review screen.
        guard quote.expiresAt - deps.now() >= FastWithdrawalQuote.minimumSecondsLeft else {
            phase = .failed(Self.message(for: FastWithdrawalQuote.Problem.expiring))
            return
        }

        // Saved BEFORE the broadcast: from here on the app always has a handle on this withdrawal.
        var saved = FastWithdrawalRecord(
            id: quote.id, walletId: walletId, requestID: requestID ?? "", sidechain: quote.sidechain,
            l1Destination: quote.l1Destination, l1PayoutSats: quote.l1PayoutSats,
            l2PaymentAddress: quote.l2PaymentAddress, l2PaymentSats: quote.l2PaymentSats,
            serviceFeeSats: quote.serviceFeeSats, expiresAt: quote.expiresAt, createdAt: deps.now(),
            paymentTxid: nil, paymentStarted: true, status: quote.status, payoutTxid: nil,
            l2ReceivedSats: 0, l2RefundAddress: nil, dismissed: false)
        deps.store.save(saved)
        record = saved
        phase = .paying

        let tx: WalletTx
        do {
            tx = try await deps.pay(quote.l2PaymentAddress, Amount(sats: quote.l2PaymentSats))
        } catch {
            if Self.failedBeforeBroadcast(error) {
                // Nothing left the wallet: forget the record and let the user fix it and try again.
                saved.paymentStarted = false
                saved.dismissed = true
                deps.store.save(saved)
                record = nil
                phase = .failed(Self.message(for: error))
            } else {
                // It may or may not have gone out. Never offer to pay again — keep tracking: the
                // service picks up a mined payment by itself.
                paymentNotice = "We couldn't confirm the payment went through. If it did, this will update once it's mined. Don't pay again."
                phase = .tracking
            }
            return
        }

        saved.paymentTxid = tx.txid
        deps.store.save(saved)
        record = saved
        deps.onPaid(tx)
        phase = .tracking
        // Locks the payment in while it's still in the mempool. Optional for the service (it finds
        // mined payments itself), so a failure here is fine — polling retries it.
        if let updated = try? await deps.service.submitPayment(withdrawalID: quote.id, txid: tx.txid,
                                                               vout: Int32(0)) {
            update(with: updated)
        }
    }

    // MARK: - Tracking

    /// Poll until the withdrawal settles or the view goes away (the task is cancelled). Backs off from
    /// 5 to 30 seconds — confirmations take minutes and the service rate-limits.
    func track() async {
        var delay: UInt64 = 5
        while !Task.isCancelled, let current = record, !current.status.isFinal {
            if let txid = current.paymentTxid,
               current.status == .awaitingPayment || current.status == .expired {
                // Still not registered: (re)submit. Idempotent on the service side.
                if let updated = try? await deps.service.submitPayment(withdrawalID: current.id, txid: txid,
                                                                       vout: Int32(0)) {
                    update(with: updated)
                }
            } else if let updated = try? await deps.service.withdrawal(id: current.id) {
                update(with: updated)
            }
            if record?.status.isFinal == true { break }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }

    private func update(with remote: FastWithdrawal) {
        guard var current = record, current.id == remote.id else { return }
        current.apply(remote)
        deps.store.save(current)
        record = current
    }

    /// Underpaid: ask for the payment back, to a fresh address of this wallet. One-shot on the service
    /// side, so the address is never typed by the user.
    func requestRefund() async {
        guard let current = record, current.status == .underpaid, current.l2RefundAddress == nil,
              !isRequestingRefund else { return }
        isRequestingRefund = true
        refundError = nil
        defer { isRequestingRefund = false }
        do {
            let address = try await deps.refundAddress()
            let updated = try await deps.service.requestRefund(withdrawalID: current.id, l2RefundAddress: address)
            update(with: updated)
            if record?.l2RefundAddress == nil, var r = record {
                r.l2RefundAddress = address
                deps.store.save(r)
                record = r
            }
        } catch {
            refundError = Self.message(for: error)
        }
    }

    /// Hide a settled withdrawal from the "in progress" list.
    func dismiss() {
        guard var current = record, current.status.isFinal else { return }
        current.dismissed = true
        deps.store.save(current)
        record = current
    }

    // MARK: - Messages

    static func failedBeforeBroadcast(_ error: Error) -> Bool {
        if let thunder = error as? ThunderError {
            switch thunder {
            case .insufficientFunds, .invalidAddress: return true
            default: return false
            }
        }
        return false
    }

    static func message(for error: Error) -> String {
        if let problem = error as? FastWithdrawalQuote.Problem {
            switch problem {
            case .badSignature, .unexpectedKey:
                return "The provider's quote couldn't be verified, so nothing was paid. Try again later."
            case .mismatch, .badAmounts:
                return "The provider's quote didn't match your request, so nothing was paid."
            case .expiring:
                return "The quote expired before it could be paid. Nothing was paid — get a new quote."
            case .notPayable:
                return "The provider isn't accepting a payment for this quote. Nothing was paid."
            }
        }
        if let error = error as? CoinNewsError {
            switch error {
            case .server(_, let message?) where !message.isEmpty:
                return "The provider declined: \(message)"
            // Connect maps both rate limiting and RESOURCE_EXHAUSTED (no liquidity, too many open
            // quotes) to 429; those carry a message and are handled above.
            case .server(let status, _) where status == 429:
                return "The provider is busy. Try again in a moment."
            case .network:
                return "Couldn't reach the fast withdrawal provider."
            default:
                return "The fast withdrawal provider returned something unexpected."
            }
        }
        if let error = error as? UserFacingError { return error.userMessage }
        if let error = error as? WalletError { return error.userMessage }
        return "Something went wrong."
    }
}
