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
    let network: WalletNetwork
    let networkDisplayName: String
    let isMainnet: Bool

    // Entry state. `addressText` accepts a bare address or a BIP21 URI (parsed when leaving the
    // recipient step).
    var addressText = ""
    private(set) var amountText = ""
    var tier: FeeTier = .normal
    private(set) var step: Step = .recipient

    /// True from the instant "Confirm send" is tapped until the device-auth prompt resolves — the
    /// send is already "in flight" here even though `step` is still `.reviewing` (we keep the review
    /// on screen behind the biometric prompt). Navigation MUST stay locked across this window:
    /// presenting the prompt flips scenePhase on iOS (and exposes system-back on Android), which can
    /// pop the Send NavigationStack; if back isn't locked, the path-sync handler walks the step
    /// machine reviewing→amount→recipient and the user lands back on the address screen mid-auth
    /// instead of reaching the success screen. See `isSendingLocked` + SendScreen's `backLocked`.
    private(set) var authorizing = false

    // Normalized at review() — what confirmSend() actually sends and the review screen shows.
    private(set) var reviewAddress = ""
    private(set) var reviewAmount: Amount = .zero

    /// True when the user tapped "Max" — the send drains the whole wallet (exact fee deducted by BDK)
    /// instead of sending the literal `amountText`. Cleared the moment the user edits the amount.
    private(set) var isMax = false

    private let send: (_ address: String, _ amount: Amount, _ feeRate: FeeRate) async throws -> WalletTx
    /// True sweep of the whole spendable balance to `address` — the correct "Max" (BDK drain).
    private let sweep: (_ address: String, _ feeRate: FeeRate) async throws -> WalletTx
    private let onSent: @MainActor (WalletTx) -> Void
    /// Device-auth gate before broadcasting (Golden Rule §7). AppState wires this to `DeviceAuth`
    /// when app-lock is on, or a pass-through when it's off. Returns true to proceed.
    private let authorize: (String) async -> Bool
    /// Validates a destination address for this wallet's network (checksum + network/prefix).
    /// Injected so the view model stays platform-agnostic; AppState wires it to BDK via WalletManager.
    private let validateAddress: (String) -> Bool

    init(balance: Amount,
         unitLabel: String,
         network: WalletNetwork,
         send: @escaping (_ address: String, _ amount: Amount, _ feeRate: FeeRate) async throws -> WalletTx,
         sweep: @escaping (_ address: String, _ feeRate: FeeRate) async throws -> WalletTx,
         onSent: @escaping @MainActor (WalletTx) -> Void,
         authorize: @escaping (String) async -> Bool,
         validateAddress: @escaping (String) -> Bool = { _ in true }) {
        self.balance = balance
        self.unitLabel = unitLabel
        self.network = network
        self.networkDisplayName = NetworkRegistry.params(for: network).displayName
        self.isMainnet = network.isMainnet
        self.send = send
        self.sweep = sweep
        self.onSent = onSent
        self.authorize = authorize
        self.validateAddress = validateAddress
    }

    // MARK: - Keypad

    func tapDigit(_ digit: Int) {
        isMax = false   // editing the amount cancels a pending Max
        amountText = AmountEntry.appendDigit(amountText, digit: digit)
    }

    func tapDot() {
        isMax = false
        amountText = AmountEntry.appendDot(amountText)
    }

    func tapBackspace() {
        isMax = false
        amountText = AmountEntry.backspace(amountText)
    }

    /// Max: send the entire spendable balance. Sets `isMax`, so `confirmSend` uses a true BDK **drain**
    /// (all UTXOs, no change, exact fee deducted) rather than the literal amount — which never fails on
    /// a fee-estimate mismatch and leaves no dust. The field shows the full balance for reference; the
    /// review notes the fee is deducted.
    func tapMax() {
        isMax = true
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

    /// The recipient step can advance only once the input parses (bare address or BIP21 URI) AND
    /// the address is VALID for this wallet's network — checksum + prefix checked up front (not just
    /// at send), so typos and wrong-network pastes are caught before amount/review/auth.
    var canContinueRecipient: Bool {
        guard let parsed = BIP21.parse(addressText) else { return false }
        return validateAddress(parsed.address)
    }

    /// The parsed, VALID destination for the current input (unwrapping a BIP21 URI), or nil. Drives
    /// the green mono confirmation under the recipient field.
    var recipientAddressPreview: String? {
        guard let parsed = BIP21.parse(addressText), validateAddress(parsed.address) else { return nil }
        return parsed.address
    }

    /// True when the input is a non-empty address that does NOT validate for this network — a typo
    /// or a wrong-network paste. Drives a red inline warning ("Not a valid <network> address").
    var recipientAddressInvalid: Bool {
        guard let parsed = BIP21.parse(addressText) else { return false }   // empty/unparseable → no error yet
        return !validateAddress(parsed.address)
    }

    /// The amount step can advance with a positive in-balance amount (recipient already chosen).
    var canReview: Bool {
        guard let amount else { return false }
        return amount.sats > 0 && !amountExceedsBalance
    }

    /// Back navigation must be disabled whenever a send is in flight: while the auth prompt is up
    /// (`authorizing`, step still `.reviewing`), while broadcasting, and on the terminal success
    /// screen (the only exit is "Done"). Only the editable steps — recipient, amount, idle review,
    /// and failed — allow stepping back. SendScreen reads this to lock both swipe-back and the
    /// path-sync handler so an auth-time scene/back event can't pop the user off the flow.
    var isSendingLocked: Bool {
        if authorizing { return true }
        switch step {
        case .broadcasting, .sent: return true
        default: return false
        }
    }

    // MARK: - Steps

    /// Recipient → amount. Parses the address (unwrapping a BIP21 URI); if the URI carries an
    /// amount and the user hasn't entered one yet, it pre-fills the amount field.
    func confirmRecipient() {
        guard step == .recipient, let parsed = BIP21.parse(addressText),
              validateAddress(parsed.address) else { return }
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
        guard step == .reviewing, !authorizing else { return }
        // Device-auth gate before moving money (§7). On cancel/failure, stay on review — no
        // broadcast. A no-op authorize (app-lock off) returns true and sends straight through.
        // `authorizing` locks navigation for the whole prompt window (see `isSendingLocked`); we
        // promote to `.broadcasting` BEFORE clearing it so there's never a synchronous gap where
        // the flow is unlocked on `.reviewing` after a successful auth.
        authorizing = true
        let approved = await authorize("Authorize this payment")
        guard approved else { authorizing = false; return }
        step = .broadcasting
        authorizing = false
        do {
            // Max → true drain (exact fee deducted, no change); otherwise the literal reviewed amount.
            let tx = isMax
                ? try await sweep(reviewAddress, tier.feeRate)
                : try await send(reviewAddress, reviewAmount, tier.feeRate)
            onSent(tx)
            step = .sent
        } catch let error as WalletError {
            step = .failed(error.userMessage)
        } catch {
            step = .failed("Couldn't send. Please try again.")
        }
    }
}
