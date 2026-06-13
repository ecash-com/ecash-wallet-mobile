// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

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

    init(viewModel: SendViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack(path: $path) {
            recipientStep
                .navigationTitle("Send to")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        // System close affordance (no spelled-out "Cancel"): the iOS-26 `.close`
                        // role renders the standard circular X; Android gets the Material close glyph.
                        #if os(iOS)
                        Button(role: .close) { dismiss() }
                        #else
                        Button { dismiss() } label: { Image(icon: Icon.close) }
                        #endif
                    }
                }
                .navigationDestination(for: SendRoute.self) { route in
                    ZStack {
                        Theme.Colors.bg0.ignoresSafeArea()
                        switch route {
                        case .amount: amountStep.navigationTitle("Amount")
                        case .review: reviewDestination.navigationTitle("Review")
                        }
                    }
                }
                .background(Theme.Colors.bg0)
        }
        // System back / swipe shortens the path → step the model back to match.
        .onChange(of: path) { oldPath, newPath in
            if newPath.count < oldPath.count {
                for _ in 0..<(oldPath.count - newPath.count) { vm.back() }
            }
        }
    }

    // MARK: - Step 1: recipient (stack root)

    private var recipientStep: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(spacing: Theme.Space.x4) {
                NetworkBadge(name: vm.networkDisplayName, isMainnet: vm.isMainnet)

                Text("Who are you paying?")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Paste a bare address or a BIP21 URI. `.plain` strips Android's Material field
                // container so only our `bg2` box shows (matches iOS); without it the field draws
                // its own gray fill inside ours — a heavy doubled-box look.
                TextField("Address or payment URI", text: $vm.addressText)
                    .textFieldStyle(.plain)
                    .font(.jbMono(14, .regular))
                    .foregroundStyle(Theme.Colors.text0)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                    .padding(Theme.Space.x3)
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

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
    }

    // MARK: - Step 2: amount

    private var amountStep: some View {
        VStack(spacing: Theme.Space.x4) {
            NetworkBadge(name: vm.networkDisplayName, isMainnet: vm.isMainnet)

            Text("To \(Self.shortAddress(vm.reviewAddress))")
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
                    Text("Max: \(vm.balance.formattedCoin())")
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
                Text("Broadcasting…")
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
            NetworkBadge(name: vm.networkDisplayName, isMainnet: vm.isMainnet)

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
                Text("The network fee is set by rate; the exact fee is deducted at send.")
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

            Spacer()

            WalletButton(title: "Confirm send") {
                Task { await vm.confirmSend() }
            }
        }
        .padding(Theme.Space.gutter)
    }

    private func reviewRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            Text(value)
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
            Text("Sent")
                .textStyle(.h2)
                .foregroundStyle(Theme.Colors.text0)
            Text("Your transaction is broadcast and pending confirmation.")
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
