// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService
import SkipQRCode   // Android camera scanner (AndroidBarcodeScanner); iOS uses QRScannerView, as Send does

/// The regular (BIP300) withdrawal from a sidechain wallet back to its mainchain: destination, amount
/// and fees, then a review that states the wait in real numbers and requires the user to acknowledge
/// it, then device auth. Pushed from `WithdrawOptionsSheet`. Mirrors `SidechainDepositScreen`.
struct SidechainWithdrawScreen: View {
    @State var vm: SidechainWithdrawViewModel
    @State var showScanner = false        // iOS camera scanner cover (Android uses an activity)
    @State var showDestinations = false   // "one of my wallets" picker sheet
    let onFinish: () -> Void

    init(viewModel: SidechainWithdrawViewModel, onFinish: @escaping () -> Void) {
        _vm = State(initialValue: viewModel)
        self.onFinish = onFinish
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x5) {
                switch vm.phase {
                case .entering:
                    entering
                case .reviewing:
                    review
                case .withdrawing:
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
        .navigationTitle(Text("Withdraw to \(vm.mainchainDisplayName)", bundle: .module,
                              comment: "withdrawal screen title; %@ is the mainchain name"))
        .inlineNavigationTitle()
        // No back gesture mid-withdrawal: leaving would hide the outcome of a broadcast in flight.
        .navigationBarBackButtonHidden(vm.isBusy)
        .task { await vm.loadTimingIfNeeded() }
        .sheet(isPresented: $showDestinations) {
            SendDestinationPicker(destinations: vm.destinations,
                                  networkDisplayName: vm.mainchainDisplayName,
                                  unitLabel: NetworkRegistry.params(for: vm.mainchain).unitLabel) { destination in
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

        fieldLabel(Text("To", bundle: .module, comment: "withdrawal destination label"))
        HStack(spacing: Theme.Space.x2) {
            TextField("\(vm.mainchainDisplayName) address", text: $vm.addressText)
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

        // The safe default: one of the user's own wallets on the mainchain.
        if vm.hasDestinations {
            Button { showDestinations = true } label: {
                HStack(spacing: Theme.Space.x2) {
                    Image(icon: Icon.wallet)
                        .resizable().scaledToFit().frame(width: 16, height: 16)
                    Text("Withdraw to one of my \(vm.mainchainDisplayName) wallets", bundle: .module,
                         comment: "withdrawal: pick one of the user's mainchain wallets; %@ is the mainchain name")
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
            statusError(Text(verbatim: destinationError))
        }

        if vm.addressText.isEmpty {
            Text("Only a \(vm.mainchainDisplayName) address. Coins sent to any other chain's address are lost.",
                 bundle: .module, comment: "withdrawal address hint; %@ is the mainchain name")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if vm.isAddressInvalid {
            statusError(Text("Not a valid \(vm.mainchainDisplayName) address", bundle: .module,
                             comment: "withdrawal address invalid for the mainchain; %@ is the mainchain name"))
        } else {
            HStack(spacing: Theme.Space.x2) {
                Image(icon: Icon.check)
                    .resizable().scaledToFit().frame(width: 14, height: 14)
                    .foregroundStyle(Theme.Colors.positive)
                Text("Valid \(vm.mainchainDisplayName) address", bundle: .module,
                     comment: "withdrawal address accepted; %@ is the mainchain name")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        fieldLabel(Text("Amount", bundle: .module, comment: "withdrawal amount label"))
        amountField($vm.amountText)
        switch vm.amountProblem {
        case .belowMinimum:
            note(Text("The minimum withdrawal is \(Amount(sats: ThunderService.minimumWithdrawalSats).formattedCoin()) \(vm.unitLabel).",
                      bundle: .module, comment: "withdrawal below dust; %1$@ amount, %2$@ unit"), negative: true)
        case .noMainFee:
            note(Text("A withdrawal needs a mainchain fee.", bundle: .module, comment: "withdrawal missing mainchain fee"),
                 negative: true)
        case .exceedsBalance:
            note(Text("Amount plus mainchain fee is more than this wallet can spend.", bundle: .module,
                      comment: "withdrawal amount + fee too large"), negative: true)
        case .none:
            note(Text("Available: \(vm.spendable.formattedCoin()) \(vm.unitLabel)", bundle: .module,
                      comment: "spendable balance under the withdrawal amount; %1$@ amount, %2$@ unit"), negative: false)
        }

        fieldLabel(Text("Mainchain fee", bundle: .module, comment: "withdrawal mainchain fee label"))
        amountField($vm.mainFeeText)
        note(Text("Your share of the fee for the \(vm.mainchainDisplayName) transaction that pays you out.",
                  bundle: .module, comment: "withdrawal mainchain fee explanation; %@ is the mainchain name"),
             negative: false)

        fieldLabel(Text("\(vm.sidechainTitle) fee", bundle: .module, comment: "withdrawal sidechain fee label; %@ is the sidechain name"))
        Picker(selection: $vm.tier) {
            Text("Slow", bundle: .module, comment: "fee tier").tag(SendViewModel.FeeTier.slow)
            Text("Normal", bundle: .module, comment: "fee tier").tag(SendViewModel.FeeTier.normal)
            Text("Fast", bundle: .module, comment: "fee tier").tag(SendViewModel.FeeTier.fast)
        } label: {
            Text("Fee", bundle: .module, comment: "withdrawal sidechain fee label")
        }
        .pickerStyle(.segmented)

        WalletButton(title: "Review") { vm.review() }
            .disabled(!vm.canReview)
            .opacity(vm.canReview ? 1 : 0.4)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.x3) {
            NetworkBadge(network: vm.sidechainNetwork)
            Image(icon: Icon.disclosure)
                .resizable().scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(Theme.Colors.text2)
            NetworkBadge(network: vm.mainchain)
            Spacer()
            Text("Regular withdrawal", bundle: .module, comment: "withdrawal kind label in the header")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text1)
        }
        .card()
    }

    // MARK: - Review (Golden Rule §7: network, recipient, amount, fee — and the wait)

    @ViewBuilder private var review: some View {
        header

        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            reviewRow(Text("From", bundle: .module, comment: "withdrawal review row"),
                      Text(verbatim: vm.sidechainTitle))
            hairline
            reviewRow(Text("To network", bundle: .module, comment: "withdrawal review row"),
                      Text(verbatim: vm.mainchainDisplayName))
            hairline
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                Text("To", bundle: .module, comment: "withdrawal destination label")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text2)
                Text(verbatim: vm.addressText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.jbMono(13, .regular))
                    .foregroundStyle(Theme.Colors.text0)
            }
            hairline
            reviewRow(Text("Amount", bundle: .module, comment: "withdrawal review row"),
                      Text(verbatim: "\(vm.amount?.formattedCoin() ?? "") \(vm.unitLabel)"))
            hairline
            reviewRow(Text("Mainchain fee", bundle: .module, comment: "withdrawal review row"),
                      Text(verbatim: "\(vm.mainFee?.formattedCoin() ?? "") \(vm.unitLabel)"))
            hairline
            reviewRow(Text("\(vm.sidechainTitle) fee", bundle: .module, comment: "withdrawal review row; %@ is the sidechain name"),
                      Text("\(vm.tier.feeRate.satPerVByte) sat/byte", bundle: .module,
                           comment: "withdrawal sidechain fee rate; %@ is the rate"))
            hairline
            reviewRow(Text("Leaves \(vm.sidechainTitle)", bundle: .module,
                           comment: "withdrawal review: payout + mainchain fee; %@ is the sidechain name"),
                      Text("\(vm.totalBeforeSidechainFee?.formattedCoin() ?? "") \(vm.unitLabel) + fee", bundle: .module,
                           comment: "withdrawal review total before the sidechain fee; %1$@ amount, %2$@ unit"))
        }
        .card()

        timingWarning

        Toggle(isOn: $vm.acknowledged) {
            Text("I understand this can take months, can't be cancelled, and my coins only arrive if miners approve it.",
                 bundle: .module, comment: "withdrawal acknowledgement toggle")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
        }
        .tint(Theme.Colors.accent)

        WalletButton(title: "Confirm withdrawal") { Task { await vm.confirm() } }
            .disabled(!vm.canConfirm)
            .opacity(vm.canConfirm ? 1 : 0.4)
        WalletButton(title: "Edit", kind: .secondary) { vm.back() }
            .disabled(vm.isBusy)
    }

    /// The whole point of this screen: how long, and what happens if it fails — with the chain's own
    /// numbers when the enforcer answered.
    private var timingWarning: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("This is a slow withdrawal.", bundle: .module, comment: "withdrawal timing warning title")
                .textStyle(.h3)
                .foregroundStyle(Theme.Colors.text0)
            Text("Miners have to approve it, one vote per \(vm.mainchainDisplayName) block. Your coins leave \(vm.sidechainTitle) now and arrive only once the vote passes.",
                 bundle: .module, comment: "withdrawal timing explanation; %1$@ mainchain, %2$@ sidechain")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
            if let blocks = vm.minimumBlocks {
                HStack(spacing: Theme.Space.x1) {
                    Text("Fastest possible:", bundle: .module, comment: "withdrawal best-case wait label")
                    ApproximateDurationText(duration: ApproximateDuration(blocks: blocks))
                }
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
            }
            if let blocks = vm.expiryBlocks {
                HStack(spacing: Theme.Space.x1) {
                    Text("If it isn't approved within", bundle: .module, comment: "withdrawal expiry label, before a duration")
                    ApproximateDurationText(duration: ApproximateDuration(blocks: blocks))
                    Text("it goes back in line and waits again.", bundle: .module, comment: "withdrawal expiry label, after a duration")
                }
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text1)
            } else {
                Text("If it isn't approved in time it goes back in line and waits again.", bundle: .module,
                     comment: "withdrawal expiry without numbers")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
            }
        }
        .padding(Theme.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warningTint, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.warning.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Outcomes

    private var working: some View {
        VStack(spacing: Theme.Space.x3) {
            ProgressView()
            Text("Submitting withdrawal…", bundle: .module, comment: "withdrawal in progress")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x10)
    }

    @ViewBuilder private func done(_ tx: WalletTx) -> some View {
        VStack(spacing: Theme.Space.x3) {
            Image(icon: Icon.pending)
                .resizable().scaledToFit()
                .frame(width: 36, height: 36)
                .foregroundStyle(Theme.Colors.accent)
            Text("Withdrawal submitted", bundle: .module, comment: "withdrawal success title")
                .textStyle(.h2)
                .foregroundStyle(Theme.Colors.text0)
            Text("Your coins have left \(vm.sidechainTitle). They'll arrive in your \(vm.mainchainDisplayName) wallet once miners approve the withdrawal — it shows as pending in Activity until then.",
                 bundle: .module, comment: "withdrawal success body; %1$@ sidechain, %2$@ mainchain")
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

        WalletButton(title: "Done") { onFinish() }
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

    private func amountField(_ text: Binding<String>) -> some View {
        HStack(spacing: Theme.Space.x2) {
            TextField("0.00000000", text: text)
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
    }

    private func note(_ text: Text, negative: Bool) -> some View {
        text
            .textStyle(.xs)
            .foregroundStyle(negative ? Theme.Colors.negative : Theme.Colors.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusError(_ text: Text) -> some View {
        text
            .textStyle(.sm)
            .foregroundStyle(Theme.Colors.negative)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

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
    /// bg1 card with a hairline border, the same chrome as the deposit flow.
    func card() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
    }
}
