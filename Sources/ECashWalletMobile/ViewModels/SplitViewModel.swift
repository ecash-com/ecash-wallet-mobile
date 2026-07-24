// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives the "Split coins" flow — a one-tap self-sweep that separates a fork-airdrop holder's eCash
/// from their Bitcoin. The destination is derived inside the engine (`splitToSelf`) — this view model
/// never handles an address, so there is no path by which a UI bug could send funds anywhere but a
/// fresh address of the same wallet. Platform-agnostic; depends only on injected closures (AppState
/// wires them to `WalletManager`). Golden Rule §7: the drain is gated behind an explicit confirm +
/// device-auth, and on any failure nothing is broadcast (the `split` closure throws, funds untouched).
@MainActor
@Observable
final class SplitViewModel {
    enum Phase: Equatable {
        case intro         // explainer + amount, awaiting confirm
        case splitting     // draining (post-auth)
        case done          // swept — success screen
        case failed(String)
    }

    /// The wallet's split status at present-time: how much is spendable and how much is pre-fork.
    let summary: SplitSummary
    let unitLabel: String
    let networkDisplayName: String
    var tier: SendViewModel.FeeTier = .normal
    private(set) var phase: Phase = .intro
    private(set) var authorizing = false

    /// The drain — no address; the engine derives a fresh wallet-owned destination.
    private let split: (_ feeRate: FeeRate) async throws -> WalletTx
    private let onDone: @MainActor (WalletTx) -> Void
    private let authorize: (String) async -> Bool

    init(summary: SplitSummary,
         unitLabel: String,
         networkDisplayName: String,
         split: @escaping (_ feeRate: FeeRate) async throws -> WalletTx,
         onDone: @escaping @MainActor (WalletTx) -> Void,
         authorize: @escaping (String) async -> Bool) {
        self.summary = summary
        self.unitLabel = unitLabel
        self.networkDisplayName = networkDisplayName
        self.split = split
        self.onDone = onDone
        self.authorize = authorize
    }

    /// The total that will move (the whole spendable balance — drain-all v1).
    var amount: Amount { Amount(sats: summary.spendableSats) }
    /// The pre-fork amount that actually needs splitting (may be < `amount` if some coins are already
    /// safe). Informational.
    var needsSplitAmount: Amount { Amount(sats: summary.needsSplitSats) }
    var needsSplitCount: Int { Int(summary.needsSplitCount) }

    var isSplitting: Bool { phase == .splitting || authorizing }
    var errorMessage: String? {
        if case .failed(let m) = phase { return m }
        return nil
    }

    /// Confirm → device-auth → drain. Only reachable from `.intro`. Mirrors `SendViewModel.confirmSend`
    /// (auth gate, no broadcast on cancel/failure).
    func confirm() async {
        guard phase == .intro, !authorizing else { return }
        authorizing = true
        let approved = await authorize("Authorize splitting your coins")
        guard approved else { authorizing = false; return }
        phase = .splitting
        authorizing = false
        do {
            let tx = try await split(tier.feeRate)
            onDone(tx)                 // insert the pending tx + refresh (summary recomputes → nudge clears)
            phase = .done
        } catch let error as WalletError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't split your coins. Please try again.")
        }
    }

    /// Retry a failed split in place.
    func retry() async {
        guard case .failed = phase else { return }
        phase = .intro
        await confirm()
    }
}
