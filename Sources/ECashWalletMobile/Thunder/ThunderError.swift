// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Typed, secret-scrubbed errors from the Thunder engine — mapped to user strings at the UI, never
/// carrying key material (Golden Rule §2), exactly like `WalletError` for the BDK path. Grows as the
/// engine develops; RPC/build cases arrive with the network layer.
enum ThunderError: Error, Equatable {
    /// The number of signing keys didn't match the number of inputs — Thunder requires exactly one
    /// authorization per input.
    case authorizationKeyCountMismatch(inputs: Int, keys: Int)
    /// No derived key matched an input's address within the search limit — the wallet can't sign an
    /// input it doesn't own (or the address set needs to be scanned deeper).
    case noKeyForInputAddress(inputIndex: Int)
    /// The count of input addresses didn't match the transaction's input count.
    case inputAddressCountMismatch(inputs: Int, addresses: Int)
}
