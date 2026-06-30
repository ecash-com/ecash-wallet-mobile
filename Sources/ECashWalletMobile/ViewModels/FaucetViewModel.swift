// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse

/// Drives the signet faucet sheet: a request against the faucet that dispenses valueless test coins
/// to the wallet's next unused receive address. Platform-agnostic; the network call is injected so
/// it's testable and runs off the main actor (the closure forwards to a nonisolated `FaucetClient`).
@MainActor
@Observable
public final class FaucetViewModel {
    public enum State: Equatable {
        case idle
        case cooldown          // within the time limit since the last success — can't request yet
        case requesting
        case success(txid: String)
        case failed(String)   // user-safe message (from FaucetError)
    }

    public private(set) var state: State

    /// The destination receive address (used for the request; not shown).
    public let address: String
    /// The network's display unit (e.g. "sBTC"), for the explanatory copy.
    public let unitLabel: String
    /// Whole test coins requested (from `FaucetRegistry`).
    public let amount: Double
    /// Seconds remaining in the cooldown when this sheet opened (0 if requestable). A snapshot — it
    /// doesn't tick live; reopening the sheet recomputes it.
    public let cooldownRemaining: TimeInterval

    private let dispense: (String, Double) async throws -> String   // (destination, amount) -> txid
    private let onSuccess: () -> Void                                // record cooldown + re-sync

    public init(address: String,
                unitLabel: String,
                amount: Double,
                cooldownRemaining: TimeInterval,
                dispense: @escaping (String, Double) async throws -> String,
                onSuccess: @escaping () -> Void) {
        self.address = address
        self.unitLabel = unitLabel
        self.amount = amount
        self.cooldownRemaining = cooldownRemaining
        self.dispense = dispense
        self.onSuccess = onSuccess
        self.state = cooldownRemaining > 0 ? .cooldown : .idle
    }

    /// "3" for a whole amount, otherwise the decimal value — no float formatting machinery needed.
    public var amountText: String {
        amount == amount.rounded() ? "\(Int(amount))" : "\(amount)"
    }

    /// Human "42 minutes" / "1h 5m" / "about a minute" for the cooldown notice (ceil to the minute).
    public var cooldownText: String {
        let minutes = Int((cooldownRemaining / 60).rounded(.up))
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return minutes <= 1 ? "about a minute" : "\(minutes) minutes"
    }

    /// Request coins. Idempotent while in flight; no-op on cooldown. On success records the cooldown
    /// + re-syncs (`onSuccess`); the sheet dismisses itself on the success transition.
    public func request() async {
        switch state {
        case .requesting, .cooldown, .success: return
        case .idle, .failed: break
        }
        state = .requesting
        do {
            let txid = try await dispense(address, amount)
            state = .success(txid: txid)
            onSuccess()
        } catch let error as FaucetError {
            state = .failed(error.userMessage)
        } catch {
            state = .failed("The faucet request failed. Try again later.")
        }
    }
}
