// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import WalletService
@testable import ECashWalletMobile

/// Parsing `s<slot>_<address>_<checksum>` deposit addresses.
@Suite struct SidechainDepositAddressTests {
    /// A real Thunder address (betanet deposit f83c5c7a…) and its checksum per thunder-rust's formula.
    static let thunder = "8twUkpctzwgbjqi5o14qWjrD9uk"

    @Test func roundTripsThroughTheDisplayForm() {
        let wrapped = SidechainDepositAddress.displayForm(address: Self.thunder, slot: 9)
        #expect(wrapped.hasPrefix("s9_\(Self.thunder)_"))
        #expect(wrapped.count == "s9_".count + Self.thunder.count + 1 + 6)
        #expect(SidechainDepositAddress.parse(wrapped, slot: 9) == .success(Self.thunder))
    }

    @Test func matchesThunderAddressesOwnDepositString() throws {
        // `ThunderAddress.depositString` implements thunder-rust's format_for_deposit independently;
        // the two must agree byte for byte.
        let address = ThunderAddress(bytes: [UInt8](repeating: 7, count: 20))
        let wrapped = address.depositString(sidechainNumber: RistrettoSidechainKeyScheme.thunder.sidechainNumber)
        #expect(SidechainDepositAddress.parse(wrapped, slot: 9) == .success(address.base58))
        #expect(SidechainDepositAddress.displayForm(address: address.base58, slot: 9) == wrapped)
    }

    @Test func acceptsTheShortAndBareForms() {
        #expect(SidechainDepositAddress.parse("s9_\(Self.thunder)", slot: 9) == .success(Self.thunder))
        #expect(SidechainDepositAddress.parse(Self.thunder, slot: 9) == .success(Self.thunder))
        #expect(SidechainDepositAddress.parse("  \(Self.thunder)\n", slot: 9) == .success(Self.thunder))
    }

    @Test func rejectsABadChecksum() {
        #expect(SidechainDepositAddress.parse("s9_\(Self.thunder)_000000", slot: 9) == .failure(.badChecksum))
    }

    @Test func checksumIsCaseInsensitive() {
        let wrapped = SidechainDepositAddress.displayForm(address: Self.thunder, slot: 9).uppercased()
        // Uppercasing the whole thing changes the address too, so only upper-case the checksum.
        let parts = wrapped.split(separator: "_").map(String.init)
        let mixed = "s9_\(Self.thunder)_\(parts[2])"
        #expect(SidechainDepositAddress.parse(mixed, slot: 9) == .success(Self.thunder))
    }

    @Test func refusesAnotherSidechainsAddress() {
        // A valid BitNames (slot 2) address must never become a Thunder deposit.
        let bitnames = SidechainDepositAddress.displayForm(address: "someaddr", slot: 2)
        #expect(SidechainDepositAddress.parse(bitnames, slot: 9) == .failure(.wrongSidechain(slot: 2)))
        #expect(SidechainDepositAddress.parse("s2_someaddr", slot: 9) == .failure(.wrongSidechain(slot: 2)))
    }

    @Test func rejectsMalformedInput() {
        #expect(SidechainDepositAddress.parse("", slot: 9) == .failure(.empty))
        #expect(SidechainDepositAddress.parse("x9_\(Self.thunder)", slot: 9) == .failure(.malformed))
        #expect(SidechainDepositAddress.parse("s999_\(Self.thunder)", slot: 9) == .failure(.malformed))
        #expect(SidechainDepositAddress.parse("s9__abc", slot: 9) == .failure(.malformed))
        #expect(SidechainDepositAddress.parse("a_b_c_d", slot: 9) == .failure(.malformed))
        #expect(SidechainDepositAddress.parse("has space", slot: 9) == .failure(.malformed))
        #expect(SidechainDepositAddress.parse(String(repeating: "a", count: 76), slot: 9) == .failure(.malformed))
    }
}

/// `SidechainDepositViewModel`: entry validation, review, auth gate, and outcomes, with fakes.
@MainActor
@Suite struct SidechainDepositViewModelTests {
    typealias Mock = SidechainsViewModelTests.MockEnforcer

    final class Calls: @unchecked Sendable {
        var deposits: [(slot: Int32, address: String, amount: Int64, feeRate: Int64, treasury: SidechainTreasury?)] = []
        var done: [WalletTx] = []
    }

    private let thunder = Sidechain(slot: 9, title: "Thunder", description: "", voteCount: 1009,
                                    proposalHeight: 967_989, activationHeight: 968_998)

    private func makeVM(enforcer: Mock = Mock(), approve: Bool = true, calls: Calls = Calls(),
                        spendable: Int64 = 1_000_000,
                        depositError: Error? = nil) -> SidechainDepositViewModel {
        SidechainDepositViewModel(
            sidechain: thunder, network: .ecashBeta, networkDisplayName: "Betanet", unitLabel: "ECX",
            spendable: Amount(sats: spendable), withdrawalBlocks: 13_150, enforcer: enforcer,
            deposit: { slot, address, amount, feeRate, treasury in
                if let depositError { throw depositError }
                calls.deposits.append((slot, address, amount.sats, feeRate.satPerVByte, treasury))
                return WalletTx(txid: "dep", netSats: -(amount.sats + 300), feeSats: 300, confirmations: 0,
                                timestampEpochSeconds: nil, isRBF: true,
                                sidechainDepositSlot: slot, sidechainDepositAddress: address)
            },
            authorize: { _ in approve },
            onDone: { calls.done.append($0) })
    }

    private func fill(_ vm: SidechainDepositViewModel, address: String? = nil, amount: String = "0.001") {
        vm.addressText = address ?? SidechainDepositAddress.displayForm(address: SidechainDepositAddressTests.thunder, slot: 9)
        vm.amountText = amount
    }

    @Test func cantReviewUntilAddressAndAmountAreValid() {
        let vm = makeVM()
        #expect(!vm.canReview)
        vm.addressText = "s2_other"                         // wrong sidechain
        vm.amountText = "0.001"
        #expect(!vm.canReview)
        fill(vm, amount: "0")
        #expect(!vm.canReview)
        fill(vm, amount: "0.02")                             // 2,000,000 > 1,000,000 spendable
        #expect(vm.amountProblem == .exceedsBalance)
        #expect(!vm.canReview)
        fill(vm)
        #expect(vm.canReview)
        #expect(vm.destination == SidechainDepositAddressTests.thunder)   // unwrapped
    }

    @Test func depositsTheBareAddressWithAFreshTreasury() async {
        let calls = Calls()
        let vm = makeVM(calls: calls)
        fill(vm)
        vm.review()
        #expect(vm.phase == .reviewing)
        await vm.confirm()

        #expect(calls.deposits.count == 1)
        let d = calls.deposits[0]
        #expect(d.slot == 9)
        #expect(d.address == SidechainDepositAddressTests.thunder)   // never the s9_…_checksum form
        #expect(d.amount == 100_000)
        #expect(d.feeRate == SendViewModel.FeeTier.normal.feeRate.satPerVByte)
        #expect(d.treasury?.valueSats == 519_790_000)                  // read from the enforcer at confirm
        #expect(calls.done.count == 1)
        if case .done(let tx) = vm.phase { #expect(tx.sidechainDepositSlot == 9) } else { Issue.record("not done") }
    }

    @Test func declinedAuthSendsNothing() async {
        let calls = Calls()
        let vm = makeVM(approve: false, calls: calls)
        fill(vm)
        vm.review()
        await vm.confirm()
        #expect(calls.deposits.isEmpty)
        #expect(vm.phase == .reviewing)   // still on review, free to try again
    }

    @Test func confirmOnlyFromReview() async {
        let calls = Calls()
        let vm = makeVM(calls: calls)
        fill(vm)
        await vm.confirm()                 // skipped review
        #expect(calls.deposits.isEmpty)
    }

    @Test func enforcerOutageFailsSafely() async {
        let enforcer = Mock()
        enforcer.failing = true
        let calls = Calls()
        let vm = makeVM(enforcer: enforcer, calls: calls)
        fill(vm)
        vm.review()
        await vm.confirm()
        #expect(calls.deposits.isEmpty)
        #expect(vm.errorMessage == "Couldn't reach the sidechain network. Nothing was sent.")
        vm.retry()
        #expect(vm.phase == .reviewing)
    }

    @Test func engineErrorsSurfaceTheirMessage() async {
        let vm = makeVM(depositError: WalletError.sidechainTreasuryBusy)
        fill(vm)
        vm.review()
        await vm.confirm()
        #expect(vm.errorMessage == WalletError.sidechainTreasuryBusy.userMessage)
    }

    @Test func emptySlotDepositsWithNoTreasury() async {
        let calls = Calls()
        let zSide = Sidechain(slot: 98, title: "zSide", description: "", voteCount: 1, proposalHeight: 1, activationHeight: 1)
        let vm = SidechainDepositViewModel(
            sidechain: zSide, network: .ecashBeta, networkDisplayName: "Betanet", unitLabel: "ECX",
            spendable: Amount(sats: 1_000_000), withdrawalBlocks: nil, enforcer: Mock(),
            deposit: { slot, address, amount, feeRate, treasury in
                calls.deposits.append((slot, address, amount.sats, feeRate.satPerVByte, treasury))
                return WalletTx(txid: "d", netSats: -1, feeSats: 1, confirmations: 0, timestampEpochSeconds: nil, isRBF: true)
            },
            authorize: { _ in true }, onDone: { _ in })
        vm.addressText = "s98_zaddr"
        vm.amountText = "0.0001"
        vm.review()
        await vm.confirm()
        #expect(calls.deposits.first?.treasury == nil)   // slot 98 has never been deposited to
        #expect(calls.deposits.first?.slot == 98)
    }
}

/// "Deposit to one of my wallets": which wallets are offered, and what picking one does.
@MainActor
@Suite struct SidechainDepositDestinationTests {
    @Test func thunderWalletsLiveInSlotNine() {
        #expect(SidechainWalletNetwork.slot(ofSidechainWallet: .thunder) == 9)
        #expect(SidechainWalletNetwork.slot(ofSidechainWallet: .ecashBeta) == nil)
    }

    @Test func onlyBetanetThunderWalletsForBetanetThunder() {
        #expect(SidechainWalletNetwork.walletNetwork(forSlot: 9, onMainchain: .ecashBeta) == .thunder)
        // Another sidechain on betanet: no wallet type for it in this app.
        #expect(SidechainWalletNetwork.walletNetwork(forSlot: 2, onMainchain: .ecashBeta) == nil)
        // Thunder on another mainchain: this app's Thunder wallets are BETANET Thunder, never offered.
        #expect(SidechainWalletNetwork.walletNetwork(forSlot: 9, onMainchain: .ecash) == nil)
        #expect(SidechainWalletNetwork.walletNetwork(forSlot: 9, onMainchain: .signet) == nil)
        #expect(SidechainWalletNetwork.walletNetwork(forSlot: 9, onMainchain: .bitcoin) == nil)
    }

    private func makeVM(address: @escaping (String) async throws -> String) -> SidechainDepositViewModel {
        SidechainDepositViewModel(
            sidechain: Sidechain(slot: 9, title: "Thunder", description: "", voteCount: 1, proposalHeight: 1, activationHeight: 1),
            network: .ecashBeta, networkDisplayName: "Betanet", unitLabel: "ECX",
            spendable: Amount(sats: 1_000_000), withdrawalBlocks: nil,
            enforcer: SidechainsViewModelTests.MockEnforcer(),
            deposit: { _, _, _, _, _ in throw WalletError.notImplemented },
            authorize: { _ in true }, onDone: { _ in },
            destinations: [SendViewModel.Destination(id: "t1", label: "My Thunder", balance: .unknown)],
            addressForDestination: address)
    }

    @Test func pickingAWalletFillsItsDepositAddress() async {
        let vm = makeVM { id in
            #expect(id == "t1")
            return SidechainDepositAddressTests.thunder
        }
        #expect(vm.hasDestinations)
        await vm.useDestination(vm.destinations[0])
        // Shown in the s9_…_checksum form the Thunder wallet itself displays…
        #expect(vm.addressText == SidechainDepositAddress.displayForm(address: SidechainDepositAddressTests.thunder, slot: 9))
        // …and the deposit still goes to the bare address.
        #expect(vm.destination == SidechainDepositAddressTests.thunder)
        #expect(vm.destinationError == nil)
    }

    @Test func aFailedLookupSaysSoAndLeavesTheFieldAlone() async {
        struct Locked: Error {}
        let vm = makeVM { _ in throw Locked() }
        vm.addressText = "typed"
        await vm.useDestination(vm.destinations[0])
        #expect(vm.addressText == "typed")
        #expect(vm.destinationError == "Couldn't get an address from My Thunder.")
    }
}
