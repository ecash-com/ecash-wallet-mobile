// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives the Send flow as discrete steps: pick recipient → set amount + fee → review →
/// broadcast → sent/failed. Platform-agnostic and testable: it depends only on injected closures
/// (AppState wires them to `WalletManager`), so the state machine never touches BDK directly.
///
/// String-editing rules live in `WalletService.AmountEntry` (parity-tested); this type owns the
/// step machine and validation.
@MainActor
@Observable
final class SendViewModel {
    enum Step: Equatable {
        case recipient        // enter / paste the destination address (or BIP21 URI)
        case amount           // keypad amount + fee tier
        case reviewing        // confirm network + recipient + amount + fee before signing
        case broadcasting
        case sent
        case failed(String)   // user-safe message (already scrubbed by WalletError)
    }

    /// v1 fee tiers — sane fixed defaults for the testnet-class networks.
    /// TODO(send-v2): fetch live estimates from the backend per CLAUDE.md §6 (never zero).
    enum FeeTier: String, CaseIterable, Hashable {
        case slow, normal, fast

        var label: String {
            switch self {
            case .slow: return "Slow"
            case .normal: return "Normal"
            case .fast: return "Fast"
            }
        }

        var feeRate: FeeRate {
            switch self {
            case .slow: return FeeRate(satPerVByte: 1)
            case .normal: return FeeRate(satPerVByte: 2)
            case .fast: return FeeRate(satPerVByte: 5)
            }
        }
    }

    // Wallet context, fixed at presentation time (the Send sheet is per-selected-wallet).
    let balance: Amount
    let unitLabel: String
    let networkDisplayName: String
    let isMainnet: Bool

    // Entry state. `addressText` accepts a bare address or a BIP21 URI (parsed when leaving the
    // recipient step).
    var addressText = ""
    private(set) var amountText = ""
    var tier: FeeTier = .normal
    private(set) var step: Step = .recipient

    // Normalized at review() — what confirmSend() actually sends and the review screen shows.
    private(set) var reviewAddress = ""
    private(set) var reviewAmount: Amount = .zero

    private let send: (_ address: String, _ amount: Amount, _ feeRate: FeeRate) async throws -> WalletTx
    private let onSent: @MainActor (WalletTx) -> Void
    /// Device-auth gate before broadcasting (Golden Rule §7). AppState wires this to `DeviceAuth`
    /// when app-lock is on, or a pass-through when it's off. Returns true to proceed.
    private let authorize: (String) async -> Bool

    init(balance: Amount,
         unitLabel: String,
         networkDisplayName: String,
         isMainnet: Bool,
         send: @escaping (_ address: String, _ amount: Amount, _ feeRate: FeeRate) async throws -> WalletTx,
         onSent: @escaping @MainActor (WalletTx) -> Void,
         authorize: @escaping (String) async -> Bool) {
        self.balance = balance
        self.unitLabel = unitLabel
        self.networkDisplayName = networkDisplayName
        self.isMainnet = isMainnet
        self.send = send
        self.onSent = onSent
        self.authorize = authorize
    }

    // MARK: - Keypad

    func tapDigit(_ digit: Int) {
        amountText = AmountEntry.appendDigit(amountText, digit: digit)
    }

    func tapDot() {
        amountText = AmountEntry.appendDot(amountText)
    }

    func tapBackspace() {
        amountText = AmountEntry.backspace(amountText)
    }

    /// Fill the full spendable balance. BDK subtracts the fee at build time, so a literal
    /// max-send can fail with insufficient-funds — that error surfaces actionably on confirm.
    /// TODO(send-v2): true max via TxBuilder drain.
    func tapMax() {
        amountText = balance.formattedCoin()
    }

    // MARK: - Validation

    var amount: Amount? { Amount.fromCoin(amountText) }

    /// Amount shown above the keypad ("0" placeholder when empty).
    var displayAmountText: String { amountText.isEmpty ? "0" : amountText }

    var amountExceedsBalance: Bool {
        guard let amount else { return false }
        return amount.sats > balance.sats
    }

    /// The recipient step can advance once the address parses (a bare address or a BIP21 URI).
    /// Address validity for the network is enforced by BDK at send time, not here.
    var canContinueRecipient: Bool {
        BIP21.parse(addressText) != nil
    }

    /// The amount step can advance with a positive in-balance amount (recipient already chosen).
    var canReview: Bool {
        guard let amount else { return false }
        return amount.sats > 0 && !amountExceedsBalance
    }

    // MARK: - Steps

    /// Recipient → amount. Parses the address (unwrapping a BIP21 URI); if the URI carries an
    /// amount and the user hasn't entered one yet, it pre-fills the amount field.
    func confirmRecipient() {
        guard step == .recipient, let parsed = BIP21.parse(addressText) else { return }
        reviewAddress = parsed.address
        if let uriAmount = parsed.amount, amountText.isEmpty {
            amountText = uriAmount.formattedCoin()
        }
        step = .amount
    }

    /// Amount → review.
    func review() {
        guard step == .amount, canReview, let amount else { return }
        reviewAmount = amount
        step = .reviewing
    }

    /// Step back one screen (amount → recipient, review → amount, failed → amount). Wired to the
    /// platform back gesture/chevron via the navigation path, so there are no custom Back buttons.
    func back() {
        switch step {
        case .amount: step = .recipient
        case .reviewing: step = .amount
        case .failed: step = .amount
        default: break
        }
    }

    /// Retry a failed broadcast in place (the "Try again" action on the failure screen) — returns
    /// to the reviewed state and re-sends the same recipient/amount/fee.
    func retry() async {
        guard case .failed = step else { return }
        step = .reviewing
        await confirmSend()
    }

    /// Broadcast (off the main actor via the injected async closure), then hand the optimistic
    /// pending tx to AppState. Golden Rule §7: only reachable from the review step the user
    /// explicitly confirmed, which states network + recipient + amount + fee.
    func confirmSend() async {
        guard step == .reviewing else { return }
        // Device-auth gate before moving money (§7). On cancel/failure, stay on review — no
        // broadcast. A no-op authorize (app-lock off) returns true and sends straight through.
        guard await authorize("Authorize this payment") else { return }
        step = .broadcasting
        do {
            let tx = try await send(reviewAddress, reviewAmount, tier.feeRate)
            onSent(tx)
            step = .sent
        } catch let error as WalletError {
            step = .failed(error.userMessage)
        } catch {
            step = .failed("Couldn't send. Please try again.")
        }
    }
}
