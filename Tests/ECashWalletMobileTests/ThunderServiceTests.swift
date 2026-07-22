// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import WalletService
@testable import ECashWalletMobile

/// The `ThunderService` skeleton: local address derivation works today; the RPC-gated ops fail loud
/// with a typed error until the Thunder node RPC is wired. The mnemonic is loaded through an injected
/// closure (the app-side sign-on-demand seam).
@MainActor
@Suite struct ThunderServiceTests {

    private static let mnemonic = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    @Test func unusedAddressIsIndexZeroGolden() async throws {
        let service = ThunderService(loadMnemonic: { _ in Self.mnemonic })
        let info = try await service.receiveAddress(walletId: "w1", unused: true)
        #expect(info.address == "38VvRdmcQREr1UAcZma98WLFVpAp")   // index-0 golden (ThunderWallet)
        #expect(info.index == 0)
    }

    @Test func newAddressAdvancesAndDiffersFromDefault() async throws {
        let service = ThunderService(loadMnemonic: { _ in Self.mnemonic })
        let a = try await service.receiveAddress(walletId: "w1", unused: false)   // first "New address" → index 1
        let b = try await service.receiveAddress(walletId: "w1", unused: false)   // → index 2
        #expect(a.index == 1)
        #expect(b.index == 2)
        #expect(a.address != b.address)                          // it actually rotates
        #expect(a.address != (try await service.receiveAddress(walletId: "w1", unused: true)).address)   // ≠ the default
    }

    @Test func revealIndexIsPerWallet() async throws {
        let service = ThunderService(loadMnemonic: { _ in Self.mnemonic })
        _ = try await service.receiveAddress(walletId: "w1", unused: false)             // w1 → index 1
        #expect(try await service.receiveAddress(walletId: "w2", unused: false).index == 1)   // w2's counter is independent
    }

    @Test func missingMnemonicThrowsTyped() async {
        let service = ThunderService(loadMnemonic: { _ in nil })
        do {
            _ = try await service.receiveAddress(walletId: "w1", unused: true)
            Issue.record("expected mnemonicUnavailable")
        } catch let error as ThunderError {
            #expect(error == .mnemonicUnavailable(walletId: "w1"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func rpcGatedOpsThrowBackendUnavailable() async {
        let service = ThunderService(loadMnemonic: { _ in Self.mnemonic })
        func expectBackendUnavailable(_ body: () throws -> Void) {
            do { try body(); Issue.record("expected backendUnavailable") }
            catch let e as ThunderError { #expect(e == .backendUnavailable) }
            catch { Issue.record("wrong error: \(error)") }
        }
        expectBackendUnavailable { _ = try service.balance(walletId: "w1") }
        expectBackendUnavailable { _ = try service.pendingBalance(walletId: "w1") }
        expectBackendUnavailable { _ = try service.transactions(walletId: "w1") }
        // async ones
        do { _ = try await service.sync(walletId: "w1"); Issue.record("expected throw") }
        catch let e as ThunderError { #expect(e == .backendUnavailable) } catch { Issue.record("wrong error") }
        do {
            _ = try await service.send(walletId: "w1", to: "x", amount: Amount(sats: 1), feeRate: FeeRate(satPerVByte: 1))
            Issue.record("expected throw")
        } catch let e as ThunderError { #expect(e == .backendUnavailable) } catch { Issue.record("wrong error") }
    }
}
