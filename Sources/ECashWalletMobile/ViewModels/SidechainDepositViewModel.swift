// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives a deposit into one sidechain: destination → amount → review → device auth → deposit.
/// Platform-agnostic; everything that touches the network or keys is an injected closure, so tests
/// drive it with fakes. Design: `docs/sidechains-ui.md` §3c; mechanics: `docs/sidechain-deposits.md`.
///
/// Safety, in the order the flow meets it:
/// - The destination is unwrapped from `s<slot>_…_<checksum>`, and the checksum and slot are
///   verified (`SidechainDepositAddress`). A BitNames address can't drift into a Thunder deposit.
/// - Review states network, sidechain + slot, destination, amount and fee, and says how long getting
///   the coins back takes, using the chain's own vote threshold (Golden Rule §7).
/// - Confirm requires device auth, then reads the treasury FRESH from the enforcer (never a cached
///   list). The engine re-verifies it against the wallet's own backend and shape-checks the
///   transaction before signing and again before broadcast.
/// - On any failure nothing was broadcast; the engine throws before sending.
@MainActor
@Observable
final class SidechainDepositViewModel {
    enum Phase: Equatable {
        case entering
        case reviewing
        case depositing
        case done(WalletTx)
        case failed(String)
    }

    let sidechain: Sidechain
    let network: WalletNetwork
    let networkDisplayName: String
    let unitLabel: String
    /// What the wallet can spend right now (confirmed + own change).
    let spendable: Amount
    /// Best-case blocks before a withdrawal back could pay out; nil if unknown. For the review copy.
    let withdrawalBlocks: Int?

    /// The user's own wallets that can receive this deposit (`SidechainWalletNetwork`), offered like
    /// Send's "Send to one of my wallets" list, through the same picker.
    let destinations: [SendViewModel.Destination]
    private(set) var isResolvingDestination = false
    private(set) var destinationError: String? = nil

    var addressText = ""
    var amountText = ""
    var tier: SendViewModel.FeeTier = .normal
    private(set) var phase: Phase = .entering
    private(set) var authorizing = false

    typealias Deposit = (_ slot: Int32, _ address: String, _ amount: Amount, _ feeRate: FeeRate,
                                   _ treasury: SidechainTreasury?) async throws -> WalletTx

    private let enforcer: any EnforcerFetching
    private let deposit: Deposit
    private let authorize: (String) async -> Bool
    private let onDone: @MainActor (WalletTx) -> Void
    private let addressForDestination: (String) async throws -> String

    init(sidechain: Sidechain, network: WalletNetwork, networkDisplayName: String, unitLabel: String,
         spendable: Amount, withdrawalBlocks: Int?, enforcer: any EnforcerFetching,
         deposit: @escaping Deposit, authorize: @escaping (String) async -> Bool,
         onDone: @escaping @MainActor (WalletTx) -> Void,
         destinations: [SendViewModel.Destination] = [],
         addressForDestination: @escaping (String) async throws -> String = { _ in "" }) {
        self.destinations = destinations
        self.addressForDestination = addressForDestination
        self.sidechain = sidechain
        self.network = network
        self.networkDisplayName = networkDisplayName
        self.unitLabel = unitLabel
        self.spendable = spendable
        self.withdrawalBlocks = withdrawalBlocks
        self.enforcer = enforcer
        self.deposit = deposit
        self.authorize = authorize
        self.onDone = onDone
    }

    // MARK: - Entering

    var hasDestinations: Bool { !destinations.isEmpty }

    /// Fill the destination from one of the user's own wallets (its current unused address, so
    /// browsing never advances its index). Same behavior as Send: the address is SHOWN, in the
    /// `s<slot>_…` form the sidechain wallet itself displays, and confirmed again at review.
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
            addressText = SidechainDepositAddress.displayForm(address: address, slot: sidechain.slot)
        } catch {
            destinationError = "Couldn't get an address from \(destination.label)."
        }
    }

    var parsedAddress: Result<String, SidechainDepositAddress.Failure> {
        SidechainDepositAddress.parse(addressText, slot: sidechain.slot)
    }

    /// The bare address, when the entry is valid.
    var destination: String? {
        if case .success(let address) = parsedAddress { return address }
        return nil
    }

    var amount: Amount? { Amount.fromCoin(amountText) }

    enum AmountProblem: Equatable {
        case none
        case exceedsBalance
    }

    var amountProblem: AmountProblem {
        guard let amount else { return .none }
        return amount.sats > spendable.sats ? .exceedsBalance : .none
    }

    var canReview: Bool {
        guard destination != nil, let amount, amount.sats > 0 else { return false }
        return amountProblem == .none
    }

    func review() {
        guard phase == .entering, canReview else { return }
        phase = .reviewing
    }

    func back() {
        if phase == .reviewing { phase = .entering }
    }

    // MARK: - Confirming

    var isBusy: Bool { phase == .depositing || authorizing }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func confirm() async {
        guard phase == .reviewing, !authorizing, let address = destination, let amount else { return }
        authorizing = true
        let approved = await authorize("Authorize deposit to \(sidechain.title)")
        authorizing = false
        guard approved else { return }
        phase = .depositing
        do {
            // Fresh, every time: a treasury moves with each deposit and withdrawal.
            let treasury = try await enforcer.treasury(slot: sidechain.slot)
            let tx = try await deposit(Int32(sidechain.slot), address, amount, tier.feeRate, treasury)
            onDone(tx)
            phase = .done(tx)
        } catch let error as WalletError {
            phase = .failed(error.userMessage)
        } catch is EnforcerError {
            phase = .failed("Couldn't reach the sidechain network. Nothing was sent.")
        } catch {
            phase = .failed(WalletError.broadcastFailed.userMessage)
        }
    }

    /// After a failure: back to review so the user can try again (e.g. after "treasury busy").
    func retry() {
        if case .failed = phase { phase = .reviewing }
    }
}
