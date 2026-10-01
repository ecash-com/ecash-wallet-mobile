// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives the regular (BIP300) withdrawal from a sidechain wallet back to its mainchain:
/// destination → amount + fees → review (+ explicit acknowledgement) → device auth → withdraw.
/// Mirrors `SidechainDepositViewModel`; everything that touches keys or the network is an injected
/// closure, so tests drive it with fakes.
///
/// Modelled on BitWindow's withdraw form (`sail_ui` `parent_chain_page.dart`): a parent-chain address,
/// an amount, a mainchain fee defaulting to 0.0001, a sidechain fee, and a total. Where it goes further,
/// on purpose:
/// - **The wait is stated, with real numbers, and must be acknowledged.** BitWindow shows no timing at
///   all. A regular withdrawal needs more than `threshold` miner upvotes (≈ 3 months at best) and its
///   batch expires after `maxAge` blocks (≈ 6 months), re-queueing rather than refunding. It can't be
///   cancelled. Both figures come from the enforcer's live BIP300 constants.
/// - **The destination is checked for the mainchain network by BDK** before anything is built. The
///   node never checks it, and eCash uses Bitcoin's address format, so a wrong-chain address would
///   look perfectly valid and lose the coins.
/// - The user's own mainchain wallets are offered first, like Send's "one of my wallets".
@MainActor
@Observable
final class SidechainWithdrawViewModel {
    enum Phase: Equatable {
        case entering
        case reviewing
        case withdrawing
        case done(WalletTx)
        case failed(String)
    }

    /// The chain's withdrawal timing, from the mainchain enforcer: the best case, the batch expiry, and
    /// the batch ALREADY being voted on for this sidechain, if any. A sidechain forms a new batch only
    /// when none is pending, so a new withdrawal waits for that one to pass or expire before its own
    /// vote can start — the "about 3 months" best case doesn't hold while one is in progress.
    struct Timing: Equatable {
        let minimumBlocks: Int
        let expiryBlocks: Int
        let batchInProgress: BatchInProgress?
    }

    struct BatchInProgress: Equatable {
        let votes: Int
        let votesNeeded: Int
        /// Blocks until it expires unpassed; nil if the mainchain tip wasn't known.
        let blocksUntilExpiry: Int?
    }

    /// BitWindow's default mainchain fee (`estimateMainchainFee` → 0.0001). It is this withdrawal's
    /// share of the mainchain payout transaction's fee; it also orders withdrawals within a full batch.
    static let defaultMainFeeSats: Int64 = 10_000

    let sidechainTitle: String
    let sidechainNetwork: WalletNetwork
    let mainchain: WalletNetwork
    let mainchainDisplayName: String
    let unitLabel: String
    /// What the sidechain wallet can spend right now (confirmed coins only — see ThunderScan).
    let spendable: Amount
    let destinations: [SendViewModel.Destination]

    private(set) var isResolvingDestination = false
    private(set) var destinationError: String? = nil
    /// Best-case blocks until the coins arrive, and blocks until a batch expires — from the enforcer.
    private(set) var minimumBlocks: Int? = nil
    private(set) var expiryBlocks: Int? = nil
    /// A batch already being voted on for this sidechain (see `Timing`); nil if none, or unknown.
    private(set) var batchInProgress: BatchInProgress? = nil

    var addressText = ""
    var amountText = ""
    var mainFeeText: String
    var tier: SendViewModel.FeeTier = .normal
    /// "I understand this takes months and can't be cancelled" — required to confirm.
    var acknowledged = false
    private(set) var phase: Phase = .entering
    private(set) var authorizing = false

    typealias Withdraw = (_ mainAddress: String, _ mainScriptPubKey: [UInt8], _ amount: Amount,
                          _ mainFee: Amount, _ feeRate: FeeRate) async throws -> WalletTx

    /// The mainchain scriptPubKey for an address, or nil if it isn't a valid address ON THE MAINCHAIN.
    private let scriptPubKey: (String) -> [UInt8]?
    private let withdraw: Withdraw
    private let authorize: (String) async -> Bool
    private let onDone: @MainActor (WalletTx) -> Void
    private let addressForDestination: (String) async throws -> String
    private let loadTiming: () async -> Timing?

    init(sidechainTitle: String, sidechainNetwork: WalletNetwork,
         mainchain: WalletNetwork, mainchainDisplayName: String, unitLabel: String,
         spendable: Amount,
         scriptPubKey: @escaping (String) -> [UInt8]?,
         withdraw: @escaping Withdraw,
         authorize: @escaping (String) async -> Bool,
         onDone: @escaping @MainActor (WalletTx) -> Void,
         loadTiming: @escaping () async -> Timing?,
         destinations: [SendViewModel.Destination] = [],
         addressForDestination: @escaping (String) async throws -> String = { _ in "" }) {
        self.sidechainTitle = sidechainTitle
        self.sidechainNetwork = sidechainNetwork
        self.mainchain = mainchain
        self.mainchainDisplayName = mainchainDisplayName
        self.unitLabel = unitLabel
        self.spendable = spendable
        self.scriptPubKey = scriptPubKey
        self.withdraw = withdraw
        self.authorize = authorize
        self.onDone = onDone
        self.loadTiming = loadTiming
        self.destinations = destinations
        self.addressForDestination = addressForDestination
        self.mainFeeText = Amount(sats: Self.defaultMainFeeSats).formattedCoin()
    }

    /// Fetch the live BIP300 timing for the review copy. Failure leaves it nil, and the copy falls back
    /// to a plain "months" without inventing numbers.
    func loadTimingIfNeeded() async {
        guard minimumBlocks == nil, let timing = await loadTiming() else { return }
        minimumBlocks = timing.minimumBlocks
        expiryBlocks = timing.expiryBlocks
        batchInProgress = timing.batchInProgress
    }

    // MARK: - Entering

    var hasDestinations: Bool { !destinations.isEmpty }

    /// Fill the destination from one of the user's own mainchain wallets — its current UNUSED
    /// address, so browsing never advances that wallet's index.
    func useDestination(_ destination: SendViewModel.Destination) async {
        guard !isResolvingDestination else { return }
        isResolvingDestination = true
        destinationError = nil
        defer { isResolvingDestination = false }
        do {
            let address = try await addressForDestination(destination.id)
            guard !address.isEmpty else {
                destinationError = "Couldn't get an address from \(destination.label)."
                return
            }
            addressText = address
        } catch {
            destinationError = "Couldn't get an address from \(destination.label)."
        }
    }

    private var trimmedAddress: String { addressText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The destination's scriptPubKey when the entry is a valid MAINCHAIN address.
    var destinationScript: [UInt8]? {
        guard !trimmedAddress.isEmpty else { return nil }
        return scriptPubKey(trimmedAddress)
    }

    var isAddressInvalid: Bool { !trimmedAddress.isEmpty && destinationScript == nil }

    var amount: Amount? { Amount.fromCoin(amountText) }
    var mainFee: Amount? { Amount.fromCoin(mainFeeText) }

    /// Payout + mainchain fee — both leave the sidechain. The sidechain fee comes on top and is only
    /// known once coins are picked (it's priced on the transaction's size).
    var totalBeforeSidechainFee: Amount? {
        guard let amount, let mainFee else { return nil }
        return Amount(sats: amount.sats + mainFee.sats)
    }

    enum AmountProblem: Equatable {
        case none
        case belowMinimum
        case noMainFee
        case exceedsBalance
    }

    var amountProblem: AmountProblem {
        guard let amount else { return .none }
        if amount.sats < ThunderService.minimumWithdrawalSats { return .belowMinimum }
        guard let mainFee, mainFee.sats > 0 else { return .noMainFee }
        return amount.sats + mainFee.sats > spendable.sats ? .exceedsBalance : .none
    }

    var canReview: Bool {
        guard destinationScript != nil, let amount, amount.sats > 0 else { return false }
        return amountProblem == .none
    }

    func review() {
        guard phase == .entering, canReview else { return }
        acknowledged = false   // re-confirm the wait on every review, never carried over from an edit
        phase = .reviewing
    }

    func back() {
        if phase == .reviewing { phase = .entering }
    }

    // MARK: - Confirming

    var isBusy: Bool { phase == .withdrawing || authorizing }
    var canConfirm: Bool { phase == .reviewing && acknowledged && !isBusy }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func confirm() async {
        guard canConfirm, let script = destinationScript, let amount, let mainFee else { return }
        let address = trimmedAddress
        authorizing = true
        let approved = await authorize("Authorize withdrawal to \(mainchainDisplayName)")
        authorizing = false
        guard approved else { return }
        phase = .withdrawing
        do {
            let tx = try await withdraw(address, script, amount, mainFee, tier.feeRate)
            onDone(tx)
            phase = .done(tx)
        } catch let error as WalletError {
            phase = .failed(error.userMessage)
        } catch let error as UserFacingError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed(WalletError.broadcastFailed.userMessage)
        }
    }

    func retry() {
        if case .failed = phase { phase = .reviewing }
    }
}
