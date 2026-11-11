// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import WalletService
@testable import ECashWalletMobile

/// "Hide retired networks": pure list/switcher filtering, and the two guard rails — never an empty
/// list, and the current account always shown.
@Suite struct RetiredNetworksTests {
    private static func account(_ network: WalletNetwork) -> WalletAccount {
        WalletAccount(network: network, scriptType: .bip84, accountIndex: 0,
                      externalDescriptor: "ext", internalDescriptor: "int",
                      storeName: WalletAccount.legacyStoreName(walletId: "w", network: network))
    }
    private static func wallet(_ id: String, on networks: [WalletNetwork], selected: WalletNetwork? = nil) -> ManagedWallet {
        let accounts = networks.map(account)
        let open = account(selected ?? networks[0])
        return ManagedWallet(id: id, label: id, keyType: .mnemonic, isBackedUp: true, sortIndex: 0,
                             selectedAccountId: open.id, accounts: accounts)
    }

    static let fresh = wallet("fresh", on: [.ecashMainnet, .bitcoin, .signet])
    static let alphanet = wallet("alpha", on: [.ecash])
    static let betanetOpenedOnEcash = wallet("beta+", on: [.ecashBeta, .ecashMainnet], selected: .ecashBeta)
    static let thunder = wallet("thunder", on: [.thunder])

    @Test func retiredOnlyMeansEveryAccountIsRetired() {
        #expect(RetiredNetworks.isRetiredOnly(Self.alphanet))
        #expect(RetiredNetworks.isRetiredOnly(Self.thunder))
        #expect(!RetiredNetworks.isRetiredOnly(Self.betanetOpenedOnEcash))   // has an eCash account
        #expect(!RetiredNetworks.isRetiredOnly(Self.fresh))
    }

    @Test func hidingDropsRetiredOnlyWalletsAndCountsThem() {
        let all = [Self.alphanet, Self.fresh, Self.thunder, Self.betanetOpenedOnEcash]
        #expect(RetiredNetworks.visibleWallets(all, hiding: true).map(\.id) == ["fresh", "beta+"])
        #expect(RetiredNetworks.hiddenCount(all, hiding: true) == 2)
        #expect(RetiredNetworks.visibleWallets(all, hiding: false).map(\.id) == ["alpha", "fresh", "thunder", "beta+"])
        #expect(RetiredNetworks.hiddenCount(all, hiding: false) == 0)
        #expect(!RetiredNetworks.isShowingRetiredFallback(all, hiding: true))
    }

    /// The guard rail: a user whose wallets are all old still sees them all — never the welcome screen.
    @Test func whenEveryWalletIsRetiredOnlyNothingIsHidden() {
        let old = [Self.alphanet, Self.thunder]
        #expect(RetiredNetworks.visibleWallets(old, hiding: true).map(\.id) == ["alpha", "thunder"])
        #expect(RetiredNetworks.hiddenCount(old, hiding: true) == 0)
        #expect(RetiredNetworks.isShowingRetiredFallback(old, hiding: true))
        #expect(!RetiredNetworks.isShowingRetiredFallback(old, hiding: false))
        #expect(!RetiredNetworks.isShowingRetiredFallback([], hiding: true))
    }

    @Test func theSwitcherKeepsTheCurrentNetworkEvenWhenRetired() {
        let offered: [WalletNetwork] = [.ecashMainnet, .bitcoin, .signet, .ecashBeta]
        #expect(RetiredNetworks.visibleNetworks(offered, current: .ecashBeta, hiding: true) == [.ecashMainnet, .bitcoin, .signet, .ecashBeta])
        #expect(RetiredNetworks.visibleNetworks(offered, current: .ecashMainnet, hiding: true) == [.ecashMainnet, .bitcoin, .signet])
        #expect(RetiredNetworks.visibleNetworks(offered, current: .ecashMainnet, hiding: false) == offered)
        // A Thunder-betanet sidechain entry goes the same way.
        #expect(RetiredNetworks.visibleNetworks([.thunder], current: .ecashBeta, hiding: true).isEmpty)
        #expect(RetiredNetworks.visibleNetworks([.thunder], current: .thunder, hiding: true) == [.thunder])
    }

    @Test func selectionMovesOffAHiddenWalletAndOnlyThen() {
        let visible = [Self.fresh, Self.betanetOpenedOnEcash]
        #expect(RetiredNetworks.selection(current: "beta+", visible: visible) == "beta+")   // visible → unchanged
        #expect(RetiredNetworks.selection(current: "alpha", visible: visible) == "fresh")   // hidden → first visible
        #expect(RetiredNetworks.selection(current: nil, visible: visible) == "fresh")
        #expect(RetiredNetworks.selection(current: "alpha", visible: []) == nil)
    }
}
