// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// A deterministic `WalletEngineProtocol` for fast unit tests that never cross the BDK seam.
/// View models depend on the protocol, so they can be driven by this mock
/// under Robolectric on both platforms without loading real BDK.
///
/// Lives in the main target (not a test target) so the app's view-model tests can import it
/// too. It's inert — returns fixtures — so shipping it is harmless; can move to a dedicated
/// test-support product later if we want it out of the production binary.
// SKIP @nobridge
public final class MockWalletEngine: WalletEngineProtocol {
    public let network: WalletNetwork

    // Fixtures the tests set up.
    public var balanceToReturn: Amount
    public var pendingBalanceToReturn: Amount = .zero
    public var addressToReturn: AddressInfo
    public var transactionsToReturn: [WalletTx]
    public var utxosToReturn: [Utxo]

    /// If set, every method throws this instead of returning — to drive error paths.
    public var errorToThrow: WalletError?

    // Call tracking for assertions.
    public private(set) var syncCallCount = 0
    public private(set) var lastSendAddress: String?
    public private(set) var lastSendAmount: Amount?
    public private(set) var lastSendFeeRate: FeeRate?

    public init(network: WalletNetwork = .testnet4,
                balance: Amount = .zero,
                address: AddressInfo = AddressInfo(address: "tb1qmockreceiveaddress", index: 0),
                transactions: [WalletTx] = [],
                utxos: [Utxo] = []) {
        self.network = network
        self.balanceToReturn = balance
        self.addressToReturn = address
        self.transactionsToReturn = transactions
        self.utxosToReturn = utxos
    }

    public func balance() throws -> Amount {
        if let error = errorToThrow { throw error }
        return balanceToReturn
    }

    public func pendingBalance() throws -> Amount {
        if let error = errorToThrow { throw error }
        return pendingBalanceToReturn
    }

    public func nextReceiveAddress() throws -> AddressInfo {
        if let error = errorToThrow { throw error }
        return addressToReturn
    }

    public func transactions() throws -> [WalletTx] {
        if let error = errorToThrow { throw error }
        return transactionsToReturn
    }

    public func nextUnusedAddress() throws -> AddressInfo {
        if let error = errorToThrow { throw error }
        return addressToReturn
    }

    public func listUtxos() throws -> [Utxo] {
        if let error = errorToThrow { throw error }
        return utxosToReturn
    }

    public func send(to address: String, amount: Amount, feeRate: FeeRate) throws -> WalletTx {
        if let error = errorToThrow { throw error }
        lastSendAddress = address
        lastSendAmount = amount
        lastSendFeeRate = feeRate
        // A deterministic pending, outgoing tx (RBF on by default, like BDK).
        return WalletTx(txid: "mocktxid",
                        netSats: -amount.sats,
                        feeSats: feeRate.satPerVByte,
                        confirmations: 0,
                        timestampEpochSeconds: nil,
                        isRBF: true)
    }

    public func sync() async throws {
        syncCallCount += 1
        if let error = errorToThrow { throw error }
    }
}

#endif // !SKIP_BRIDGE — bridged module: bodies excluded from the bridge compile
