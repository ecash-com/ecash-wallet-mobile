// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// An app-side error that knows how to explain itself — the counterpart of `WalletError.userMessage`
/// for errors that don't come through the BDK bridge (today, the Fuse-native Thunder engine). Without
/// it every Thunder failure collapsed into one catch-all ("Couldn't reach the network" / "Couldn't
/// send"), which hid real, fixable causes (2026-09-30).
protocol UserFacingError: Error {
    var userMessage: String { get }
}

extension ThunderError: UserFacingError {
    var userMessage: String {
        switch self {
        case .insufficientFunds:
            return "Not enough confirmed funds. Coins from a recent transaction can be spent once the next Thunder block confirms them."
        case .invalidAddress:
            return "That isn't a valid Thunder address."
        case .mnemonicUnavailable:
            return "Couldn't unlock this wallet's keys."
        case .backendUnavailable:
            return "Couldn't reach the Thunder network. Check your connection and try again."
        case let .withdrawalTooSmall(minimumSats):
            return "A withdrawal must be at least \(minimumSats) sats, with a mainchain fee."
        case .unsupportedOperation:
            return "That isn't available on Thunder."
        case .historyUnavailable:
            return "This Thunder server can't show transaction history."
        case .authorizationKeyCountMismatch, .noKeyForInputAddress, .inputAddressCountMismatch:
            return "Couldn't sign this transaction."
        }
    }
}

extension ThunderBackendError: UserFacingError {
    var userMessage: String {
        switch self {
        case .network:
            return "Couldn't reach the Thunder network. Check your connection and try again."
        case .badURL:
            return "The Thunder server address in Settings isn't valid."
        case .indexEmpty:
            return "The Thunder server hasn't caught up with the chain yet. Try again shortly."
        case .malformedResponse:
            return "The Thunder server sent a response the app couldn't read."
        case let .server(code, message):
            if Self.isUnconfirmedInput(message) {
                return "Some of these coins aren't confirmed yet. Try again after the next Thunder block."
            }
            return code >= 500
                ? "The Thunder server had a problem. Try again shortly."
                : "The Thunder network rejected this transaction."
        }
    }

    /// The node refuses to spend an output that isn't in its utreexo accumulator — i.e. one created by
    /// a transaction that isn't in a block yet. Its error text (live, 2026-09-30):
    /// `… state error: utreexo error (Could not find node)`.
    static func isUnconfirmedInput(_ message: String) -> Bool {
        message.contains("utreexo") && message.contains("Could not find node")
    }
}
