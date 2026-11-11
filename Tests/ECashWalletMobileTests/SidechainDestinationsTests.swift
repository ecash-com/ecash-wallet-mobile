// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import WalletService
@testable import ECashWalletMobile

/// The "one of my wallets" rows for a sidechain deposit or withdrawal. The bug this pins (1.5.0):
/// the list was filtered on the network a wallet was SWITCHED to, so under the seed-container
/// model — where the depositing wallet is on eCash by definition — nobody was ever listed.
@Suite struct SidechainDestinationsTests {
    private static func account(_ network: WalletNetwork) -> WalletAccount {
        WalletAccount(network: network, scriptType: .bip84, accountIndex: 0,
                      externalDescriptor: "ext", internalDescriptor: "int",
                      storeName: WalletAccount.legacyStoreName(walletId: "w", network: network))
    }
    private static func wallet(_ id: String, on networks: [WalletNetwork], keyType: WalletKeyType = .mnemonic,
                               selected: WalletNetwork? = nil) -> ManagedWallet {
        let accounts = networks.map(account)
        let open = account(selected ?? networks[0])
        return ManagedWallet(id: id, label: "Wallet \(id)", keyType: keyType, isBackedUp: true, sortIndex: 0,
                             selectedAccountId: open.id, accounts: accounts)
    }

    static let me = wallet("me", on: [.ecashMainnet, .bitcoin, .signet])
    static let other = wallet("other", on: [.ecashMainnet, .bitcoin, .signet])
    static let onThunder = wallet("t", on: [.ecashMainnet, .thunderMainnet], selected: .thunderMainnet)
    static let wif = wallet("wif", on: [.ecashMainnet, .bitcoin], keyType: .wif)
    static let bitcoinOnly = wallet("btc", on: [.bitcoin])

    @Test func depositListsEverySeedWalletWithThisOneFirstAndMarked() {
        let rows = SidechainDestinations.deposit(wallets: [Self.other, Self.onThunder, Self.me, Self.wif],
                                                 currentId: "me", receiving: .thunderMainnet) { _ in .unknown }
        #expect(rows.map(\.id) == ["me", "other", "t"])
        #expect(rows.map(\.isCurrent) == [true, false, false])
        #expect(rows[0].label == "Wallet me")
    }

    @Test func depositExcludesSingleKeyWalletsAndNonThunderSidechains() {
        #expect(SidechainDestinations.deposit(wallets: [Self.wif], currentId: "wif", receiving: .thunderMainnet) { _ in .unknown }.isEmpty)
        #expect(SidechainDestinations.deposit(wallets: [Self.me], currentId: "me", receiving: nil) { _ in .unknown }.isEmpty)
        #expect(SidechainDestinations.deposit(wallets: [Self.me], currentId: "me", receiving: .bitcoin) { _ in .unknown }.isEmpty)
    }

    @Test func depositRowsCarryTheBalanceTheCallerLooksUp() {
        let rows = SidechainDestinations.deposit(wallets: [Self.me], currentId: "me", receiving: .thunderMainnet) { id in
            id == "me" ? .known(Amount(sats: 42)) : .unknown
        }
        #expect(rows.first?.balance == .known(Amount(sats: 42)))
    }

    @Test func withdrawListsWalletsWithAnAccountOnTheMainchainThisOneFirst() {
        let rows = SidechainDestinations.withdraw(wallets: [Self.bitcoinOnly, Self.other, Self.onThunder, Self.wif],
                                                  currentId: "t", mainchain: .ecashMainnet) { _ in .unknown }
        #expect(rows.map(\.id) == ["t", "other", "wif"])   // the Bitcoin-only wallet can't take eCash
        #expect(rows[0].isCurrent && !rows[1].isCurrent)
    }
}
