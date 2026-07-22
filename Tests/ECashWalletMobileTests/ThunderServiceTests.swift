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
@Suite struct ThunderServiceTests {

    private static let mnemonic = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    @Test func nextReceiveAddressDerivesLocally() throws {
        let service = ThunderService(loadMnemonic: { _ in Self.mnemonic })
        let info = try service.nextReceiveAddress(walletId: "w1")
        #expect(info.address == "38VvRdmcQREr1UAcZma98WLFVpAp")   // the index-0 golden (ThunderWallet)
        #expect(info.index == 0)
    }

    @Test func nextUnusedFallsBackToReceiveForNow() throws {
        let service = ThunderService(loadMnemonic: { _ in Self.mnemonic })
        #expect(try service.nextUnusedAddress(walletId: "w1") == service.nextReceiveAddress(walletId: "w1"))
    }

    @Test func missingMnemonicThrowsTyped() {
        let service = ThunderService(loadMnemonic: { _ in nil })
        do {
            _ = try service.nextReceiveAddress(walletId: "w1")
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
