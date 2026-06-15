// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService
import SkipQRCode   // Android camera scanner (AndroidBarcodeScanner); iOS uses QRScannerView

/// Routes pushed onto the Send navigation stack. Recipient is the stack root; amount and review
/// are pushed, so each gets the platform back chevron + swipe-back for free (no custom Back).
enum SendRoute: Hashable {
    case amount
    case review
}

/// The Send flow, presented as a full-screen cover from Home. Real navigation steps:
/// recipient (root) → amount → review → broadcast → sent/failed (Golden Rule §7). The nav `path`
/// mirrors the view model's step; system back/swipe pops it, and `.onChange` resyncs the model.
struct SendScreen: View {
    @Environment(\.dismiss) var dismiss
    @State var vm: SendViewModel   // not `private` — Fuse bridges @State (skip-fuse rule)
    @State var path: [SendRoute] = []
    @State var showMainnetConfirm = false   // extra explicit gate for real-money sends (Golden Rule §6/§7)
    @State var showScanner = false          // iOS camera scanner cover (Android uses an activity)

    init(viewModel: SendViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack(path: $path) {
            recipientStep
                .navigationTitle(Text("Send to", bundle: .module, comment: "send recipient step title"))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        CloseToolbarButton { dismiss() }
                    }
                }
                .navigationDestination(for: SendRoute.self) { route in
                    ZStack {
                        Theme.Colors.bg0.ignoresSafeArea()
                        switch route {
                        case .amount: amountStep.navigationTitle(Text("Amount", bundle: .module, comment: "send amount step title"))
                        case .review:
                            reviewDestination
                                .navigationTitle(Text("Review", bundle: .module, comment: "send review step title"))
                                // Once broadcasting/sent, the only way out is "Done" — no back button.
                                .navigationBarBackButtonHidden(backLocked)
                        }
                    }
                }
                .background(Theme.Colors.bg0)
        }
        // System back / swipe shortens the path → step the model back to match. Except once the send
        // is in flight or succeeded: there's nothing to go back to, so undo any pop (blocks swipe +
        // Android system-back). Combined with the hidden back button, "Done" is the only exit.
        .onChange(of: path) { oldPath, newPath in
            guard newPath.count < oldPath.count else { return }
            if backLocked {
                path = oldPath
                return
            }
            for _ in 0..<(oldPath.count - newPath.count) { vm.back() }
        }
    }

    /// True while a send is broadcasting or has succeeded — back navigation is disabled in both.
    private var backLocked: Bool {
        switch vm.step {
        case .broadcasting, .sent: return true
        default: return false
        }
    }

    // MARK: - Step 1: recipient (stack root)

    private var recipientStep: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(spacing: Theme.Space.x4) {
                NetworkBadge(network: vm.network)

                Text("Who are you paying?", bundle: .module, comment: "send recipient prompt")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Paste a bare address or a BIP21 URI, or tap the trailing scan icon. `.plain` strips
                // Android's Material field container so only our `bg2` box shows (matches iOS).
                HStack(spacing: Theme.Space.x2) {
                    TextField("Address or payment URI", text: $vm.addressText)
                        .textFieldStyle(.plain)
                        .font(.jbMono(14, .regular))
                        .foregroundStyle(Theme.Colors.text0)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Scan a QR. Android → SkipQRCode's ML Kit activity; iOS → the AVFoundation cover.
                    Button { startScan() } label: {
                        Image(icon: Icon.scan)
                            .resizable().scaledToFit().frame(width: 20, height: 20)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
                .fieldBoxInset()
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

                // Once the input parses to a valid address (bare or BIP21), confirm it back in mono.
                if let preview = vm.recipientAddressPreview {
                    HStack(alignment: .top, spacing: Theme.Space.x2) {
                        Image(icon: Icon.check)
                            .resizable().scaledToFit().frame(width: 14, height: 14)
                            .foregroundStyle(Theme.Colors.positive)
                        Text(verbatim: preview)
                            .font(.jbMono(13, .regular))
                            .foregroundStyle(Theme.Colors.text1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                WalletButton(title: "Next") {
                    vm.confirmRecipient()
                    if vm.step == .amount { path.append(.amount) }
                }
                .disabled(!vm.canContinueRecipient)
                .opacity(vm.canContinueRecipient ? 1 : 0.4)
            }
            .padding(Theme.Space.gutter)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showScanner) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { code in
                    vm.addressText = code   // BIP21 is parsed when leaving the recipient step
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

    /// Launch the platform scanner: SkipQRCode's full-screen activity on Android (its completion
    /// fires off-main, so hop to the main actor to set the field), the camera cover on iOS.
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

    // MARK: - Step 2: amount

    private var amountStep: some View {
        VStack(spacing: Theme.Space.x4) {
            NetworkBadge(network: vm.network)

            Text("To \(Self.shortAddress(vm.reviewAddress))", bundle: .module, comment: "send amount recipient recap; %@ is a shortened address")
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text2)

            Spacer()

            VStack(spacing: Theme.Space.x1) {
                Text(vm.displayAmountText)
                    .font(.jbMono(40, .medium))
                    .foregroundStyle(vm.amountExceedsBalance ? Theme.Colors.negative : Theme.Colors.text0)
                Text(vm.unitLabel)
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
                Button { vm.tapMax() } label: {
                    Text("Max: \(vm.balance.formattedCoin())", bundle: .module, comment: "send max-amount button; %@ is the spendable balance")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            feeTierPicker

            Keypad(onDigit: { vm.tapDigit($0) },
                   onDot: { vm.tapDot() },
                   onBackspace: { vm.tapBackspace() })

            WalletButton(title: "Review") {
                vm.review()
                if vm.step == .reviewing { path.append(.review) }
            }
            .disabled(!vm.canReview)
            .opacity(vm.canReview ? 1 : 0.4)
        }
        .padding(Theme.Space.gutter)
    }

    /// Middle-ellipsis truncation for the recipient recap (`tb1qab…k4f2`); full address on review.
    private static func shortAddress(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }

    private var feeTierPicker: some View {
        Picker("Fee", selection: $vm.tier) {
            ForEach(SendViewModel.FeeTier.allCases, id: \.self) { tier in
                Text(tier.label).tag(tier)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Step 3: review destination (review / broadcasting / sent / failed)

    @ViewBuilder
    private var reviewDestination: some View {
        switch vm.step {
        case .broadcasting:
            VStack(spacing: Theme.Space.x4) {
                ProgressView()
                Text("Broadcasting…", bundle: .module, comment: "send broadcast in progress")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
            }
        case .sent:
            sent
        case .failed(let message):
            failed(message)
        default:
            review   // .reviewing (and any transient)
        }
    }

    private var review: some View {
        VStack(spacing: Theme.Space.x5) {
            NetworkBadge(network: vm.network)

            VStack(spacing: Theme.Space.x1) {
                Text(vm.reviewAmount.formattedCoin())
                    .font(.jbMono(36, .medium))
                    .foregroundStyle(Theme.Colors.text0)
                Text(vm.unitLabel)
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
            }

            VStack(alignment: .leading, spacing: Theme.Space.x3) {
                reviewRow(label: "To", value: vm.reviewAddress)
                reviewRow(label: "Network", value: vm.networkDisplayName)
                reviewRow(label: "Fee", value: "\(vm.tier.label) · \(vm.tier.feeRate.satPerVByte) sat/vB")
                Text("The network fee is set by rate; the exact fee is deducted at send.",
                     bundle: .module, comment: "send review fee explainer")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )

            // Real-money sends carry an extra, visible warning on top of the auth gate.
            if vm.isMainnet {
                Text("Real bitcoin — this transaction is irreversible.",
                     bundle: .module, comment: "mainnet send warning")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            WalletButton(title: "Confirm send") {
                // Mainnet gets a second, explicit confirmation before broadcast (Golden Rule §6/§7);
                // testnet-class networks send straight through the existing auth gate.
                if vm.isMainnet {
                    showMainnetConfirm = true
                } else {
                    Task { await vm.confirmSend() }
                }
            }
        }
        .padding(Theme.Space.gutter)
        .alert(Text("Send real bitcoin?", bundle: .module, comment: "mainnet send confirmation title"),
               isPresented: $showMainnetConfirm) {
            Button(role: .cancel) { } label: {
                Text("Cancel", bundle: .module, comment: "cancel mainnet send")
            }
            Button(role: .destructive) {
                Task { await vm.confirmSend() }
            } label: {
                Text("Send", bundle: .module, comment: "confirm mainnet send")
            }
        } message: {
            Text("This sends real bitcoin on \(vm.networkDisplayName). It cannot be undone.",
                 bundle: .module, comment: "mainnet send confirmation body; %@ is the network name")
        }
    }

    private func reviewRow(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label, bundle: .module)
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            Text(verbatim: value)
                .font(.jbMono(14, .regular))
                .foregroundStyle(Theme.Colors.text0)
        }
    }

    // MARK: - Terminal states

    private var sent: some View {
        VStack(spacing: Theme.Space.x4) {
            Image(icon: Icon.check)
                .resizable().scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.Colors.positive)
            Text("Sent", bundle: .module, comment: "send success heading")
                .textStyle(.h2)
                .foregroundStyle(Theme.Colors.text0)
            Text("Your transaction is broadcast and pending confirmation.",
                 bundle: .module, comment: "send success note")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
                .multilineTextAlignment(.center)
            WalletButton(title: "Done") {
                dismiss()
            }
        }
        .padding(Theme.Space.gutter)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: Theme.Space.x4) {
            Image(icon: Icon.caution)
                .resizable().scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.Colors.negative)
            Text(message)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
                .multilineTextAlignment(.center)
            WalletButton(title: "Try again") {
                Task { await vm.retry() }
            }
        }
        .padding(Theme.Space.gutter)
    }
}
