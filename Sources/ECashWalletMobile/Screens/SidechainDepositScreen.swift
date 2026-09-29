// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService
import SkipQRCode   // Android camera scanner (AndroidBarcodeScanner); iOS uses QRScannerView, as Send does

/// Route for pushing the deposit flow inside the Sidechains navigation stack.
struct SidechainDepositRoute: Hashable {
    let slot: Int
}

/// Deposit into one sidechain: destination and amount, then a review that states network,
/// sidechain, destination, amount, fee and how long getting the coins back takes, then device auth.
/// Pushed from `SidechainDetailScreen`. Design: `docs/sidechains-ui.md` §3c.
struct SidechainDepositScreen: View {
    @Environment(\.dismiss) var dismiss   // not `private` — Fuse bridges view properties
    @State var vm: SidechainDepositViewModel
    @State var showScanner = false        // iOS camera scanner cover (Android uses an activity)
    @State var showDestinations = false   // "one of my wallets" picker sheet

    init(viewModel: SidechainDepositViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x5) {
                switch vm.phase {
                case .entering:
                    entering
                case .reviewing:
                    review
                case .depositing:
                    working
                case .done(let tx):
                    done(tx)
                case .failed(let message):
                    failed(message)
                }
            }
            .padding(Theme.Space.gutter)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.bg0)
        .navigationTitle(Text("Deposit to \(vm.sidechain.title)", bundle: .module,
                              comment: "deposit screen title; %@ is the sidechain name"))
        .inlineNavigationTitle()
        // No back gesture mid-deposit: leaving would hide the outcome of a broadcast in flight.
        .navigationBarBackButtonHidden(vm.isBusy)
        // The same picker Send uses, listing the user's wallets on THIS sidechain.
        .sheet(isPresented: $showDestinations) {
            SendDestinationPicker(destinations: vm.destinations,
                                  networkDisplayName: vm.sidechain.title,
                                  unitLabel: NetworkRegistry.params(for: .thunder).unitLabel) { destination in
                // Deriving a Thunder address reads the Keychain, so it runs after the sheet closes.
                Task { await vm.useDestination(destination) }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showScanner) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { code in
                    vm.addressText = code
                    showScanner = false
                }
                .ignoresSafeArea()

                Button { showScanner = false } label: {
                    Image(icon: Icon.close)
                        .resizable().scaledToFit().frame(width: 20, height: 20)
                        .foregroundStyle(.white)
                        .padding(Theme.Space.x3)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .padding(Theme.Space.x4)
            }
        }
        #endif
    }

    /// Same scanner as Send: SkipQRCode's activity on Android (completion is off-main), the camera
    /// cover on iOS.
    private func startScan() {
        #if os(iOS)
        showScanner = true
        #else
        AndroidBarcodeScanner.scan { code in
            guard let code else { return }
            Task { @MainActor in vm.addressText = code }
        }
        #endif
    }

    // MARK: - Entering

    @ViewBuilder private var entering: some View {
        header

        fieldLabel(Text("To", bundle: .module, comment: "deposit destination label"))
        HStack(spacing: Theme.Space.x2) {
            TextField("s\(vm.sidechain.slot)_…", text: $vm.addressText)
                .textFieldStyle(.plain)
                .font(.jbMono(14, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let pasted = Clipboard.paste() {
                    vm.addressText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Text("Paste", bundle: .module, comment: "send: paste an address from the clipboard")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)

            Button { startScan() } label: {
                Image(icon: Icon.scan)
                    .resizable().scaledToFit().frame(width: 20, height: 20)
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .fieldBoxInset()
        .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

        // Send's shortcut: deposit to one of the user's own wallets on this sidechain, without
        // copying an address by hand. Hidden when they have none.
        if vm.hasDestinations {
            Button { showDestinations = true } label: {
                HStack(spacing: Theme.Space.x2) {
                    Image(icon: Icon.wallet)
                        .resizable().scaledToFit().frame(width: 16, height: 16)
                    Text("Deposit to one of my wallets", bundle: .module,
                         comment: "deposit: pick one of the user's sidechain wallets as the destination")
                        .textStyle(.sm)
                    if vm.isResolvingDestination {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .foregroundStyle(Theme.Colors.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(vm.isResolvingDestination)
        }

        if let destinationError = vm.destinationError {
            Text(verbatim: destinationError)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.negative)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        addressStatus

        fieldLabel(Text("Amount", bundle: .module, comment: "deposit amount label"))
        HStack(spacing: Theme.Space.x2) {
            TextField("0.00000000", text: $vm.amountText)
                .textFieldStyle(.plain)
                .textStyle(.mono)
                .foregroundStyle(Theme.Colors.text0)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .fieldBoxInset()
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            Text(verbatim: vm.unitLabel)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text2)
        }
        if vm.amountProblem == .exceedsBalance {
            Text("More than this wallet can spend.", bundle: .module, comment: "deposit amount too large")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.negative)
        } else {
            Text("Available: \(vm.spendable.formattedCoin()) \(vm.unitLabel)", bundle: .module,
                 comment: "spendable balance under the deposit amount; %1$@ amount, %2$@ unit")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }

        fieldLabel(Text("Fee", bundle: .module, comment: "deposit fee label"))
        Picker(selection: $vm.tier) {
            Text("Slow", bundle: .module, comment: "fee tier").tag(SendViewModel.FeeTier.slow)
            Text("Normal", bundle: .module, comment: "fee tier").tag(SendViewModel.FeeTier.normal)
            Text("Fast", bundle: .module, comment: "fee tier").tag(SendViewModel.FeeTier.fast)
        } label: {
            Text("Fee", bundle: .module, comment: "deposit fee label")
        }
        .pickerStyle(.segmented)

        WalletButton(title: "Review") { vm.review() }
            .disabled(!vm.canReview)
            .opacity(vm.canReview ? 1 : 0.4)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.x3) {
            Image(icon: Icon.sidechains)
                .resizable().scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(Theme.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: vm.sidechain.title)
                    .textStyle(.h3)
                    .foregroundStyle(Theme.Colors.text0)
                SlotLabel(slot: vm.sidechain.slot)
            }
            Spacer()
            NetworkBadge(network: vm.network)
        }
        .card()
    }

    /// Send's pattern: a valid address shows a green ✓ and the address the deposit will credit
    /// (unwrapped from `s<slot>_…`); an invalid one says why, in red.
    @ViewBuilder private var addressStatus: some View {
        if vm.addressText.isEmpty {
            Text("Paste the deposit address from your \(vm.sidechain.title) wallet.", bundle: .module,
                 comment: "deposit address hint; %@ is the sidechain name")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            switch vm.parsedAddress {
            case .success(let address):
                HStack(alignment: .top, spacing: Theme.Space.x2) {
                    Image(icon: Icon.check)
                        .resizable().scaledToFit().frame(width: 14, height: 14)
                        .foregroundStyle(Theme.Colors.positive)
                    Text(verbatim: address)
                        .font(.jbMono(13, .regular))
                        .foregroundStyle(Theme.Colors.text1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .failure(.badChecksum):
                statusError(Text("This address has a typo. Check it and try again.", bundle: .module,
                                 comment: "deposit address checksum mismatch"))
            case .failure(.wrongSidechain(let slot)):
                statusError(Text("This address is for slot \(String(slot)), not \(vm.sidechain.title).", bundle: .module,
                                 comment: "deposit address for another sidechain; %1$@ slot, %2$@ name"))
            case .failure:
                statusError(Text("Not a valid \(vm.sidechain.title) address", bundle: .module,
                                 comment: "deposit address malformed; %@ is the sidechain name"))
            }
        }
    }

    private func statusError(_ text: Text) -> some View {
        text
            .textStyle(.sm)
            .foregroundStyle(Theme.Colors.negative)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Review (Golden Rule §7: network, recipient, amount, fee)

    @ViewBuilder private var review: some View {
        header

        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            reviewRow(Text("Network", bundle: .module, comment: "deposit review row"),
                      Text(verbatim: vm.networkDisplayName))
            hairline
            reviewRow(Text("Sidechain", bundle: .module, comment: "deposit review row"),
                      Text("\(vm.sidechain.title) · slot \(String(vm.sidechain.slot))", bundle: .module,
                           comment: "tx detail: sidechain name and slot; %1$@ name, %2$@ slot number"))
            hairline
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                Text("To", bundle: .module, comment: "deposit destination label")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text2)
                if let address = vm.destination {
                    Text(verbatim: SidechainDepositAddress.displayForm(address: address, slot: vm.sidechain.slot))
                        .font(.jbMono(13, .regular))
                        .foregroundStyle(Theme.Colors.text0)
                }
            }
            hairline
            reviewRow(Text("Amount", bundle: .module, comment: "deposit review row"),
                      Text(verbatim: "\(vm.amount?.formattedCoin() ?? "") \(vm.unitLabel)"))
            hairline
            reviewRow(Text("Fee rate", bundle: .module, comment: "deposit review row"),
                      Text(verbatim: "\(vm.tier.feeRate.satPerVByte) \(NetworkRegistry.params(for: vm.network).subUnitLabel)/vB"))
        }
        .card()

        // The one-way-ness, stated before the user commits.
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text("Coins on \(vm.sidechain.title) come back by withdrawal, which takes months of miner votes. Only deposit what you mean to use there.",
                 bundle: .module, comment: "deposit review warning; %@ is the sidechain name")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
            if let blocks = vm.withdrawalBlocks {
                HStack(spacing: Theme.Space.x1) {
                    Text("Minimum wait to withdraw:", bundle: .module, comment: "deposit review: withdrawal wait label")
                    ApproximateDurationText(duration: ApproximateDuration(blocks: blocks))
                }
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text1)
            }
        }
        .padding(Theme.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warningTint, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.warning.opacity(0.4), lineWidth: 1))

        WalletButton(title: "Confirm deposit") { Task { await vm.confirm() } }
            .disabled(vm.isBusy)
            .opacity(vm.isBusy ? 0.4 : 1)
        WalletButton(title: "Edit", kind: .secondary) { vm.back() }
            .disabled(vm.isBusy)
    }

    // MARK: - Outcomes

    private var working: some View {
        VStack(spacing: Theme.Space.x3) {
            ProgressView()
            Text("Depositing…", bundle: .module, comment: "deposit in progress")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x10)
    }

    @ViewBuilder private func done(_ tx: WalletTx) -> some View {
        VStack(spacing: Theme.Space.x3) {
            Image(icon: Icon.check)
                .resizable().scaledToFit()
                .frame(width: 36, height: 36)
                .foregroundStyle(Theme.Colors.positive)
            Text("Deposit sent", bundle: .module, comment: "deposit success title")
                .textStyle(.h2)
                .foregroundStyle(Theme.Colors.text0)
            Text("It reaches your \(vm.sidechain.title) wallet once this transaction confirms.", bundle: .module,
                 comment: "deposit success body; %@ is the sidechain name")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
                .multilineTextAlignment(.center)
            Text(verbatim: tx.txid)
                .font(.jbMono(12, .regular))
                .foregroundStyle(Theme.Colors.text2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x8)

        WalletButton(title: "Done") { dismiss() }
    }

    @ViewBuilder private func failed(_ message: String) -> some View {
        VStack(spacing: Theme.Space.x3) {
            Image(icon: Icon.caution)
                .resizable().scaledToFit()
                .frame(width: 32, height: 32)
                .foregroundStyle(Theme.Colors.negative)
            Text(verbatim: message)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x8)

        WalletButton(title: "Try again") { vm.retry() }
    }

    // MARK: - Pieces

    private func fieldLabel(_ text: Text) -> some View {
        text.textStyle(.overline).foregroundStyle(Theme.Colors.text1)
    }

    private func reviewRow(_ label: Text, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x3) {
            label.textStyle(.sm).foregroundStyle(Theme.Colors.text2)
            Spacer(minLength: Theme.Space.x4)
            value.font(.jbMono(13, .regular)).foregroundStyle(Theme.Colors.text0).multilineTextAlignment(.trailing)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.Colors.border).frame(height: 1)
    }
}

private extension View {
    /// bg1 card with a hairline border, the same chrome as the tx detail cards.
    func card() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
    }
}
