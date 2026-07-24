// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The "Split coins" sheet — separates a fork-airdrop holder's eCash from their Bitcoin by draining
/// the wallet to a fresh address of ITSELF (the engine derives the destination; no address is entered
/// here). Explainer → confirm (device-auth) → success. All `Theme` tokens + shared components.
struct SplitCoinsView: View {
    @Environment(AppState.self) var app
    @State var vm: SplitViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)

    init(viewModel: SplitViewModel) { _vm = State(initialValue: viewModel) }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.x5) {
                    switch vm.phase {
                    case .done: successContent
                    default:    introContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.gutter)
            }
        }
        .obscuredWhenBackgrounded()
    }

    // MARK: - Intro / confirm

    private var introContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            Text("Separate your eCash from your Bitcoin", bundle: .module, comment: "split coins heading")
                .textStyle(.h1)
                .foregroundStyle(Theme.Colors.text0)

            Text("Right now your eCash and Bitcoin share the same coins. This moves your eCash to a new address in this wallet, so spending it can never move your Bitcoin. Do this before you spend your Bitcoin elsewhere.",
                 bundle: .module, comment: "split coins explainer")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)

            // What moves — the full spendable balance (drain-all), plus how much actually needs it.
            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                amountRow(labelKey: "Amount to move", value: vm.amount.formattedCoin())
                if vm.needsSplitCount > 0 {
                    amountRow(labelKey: "Needs splitting",
                              value: vm.needsSplitAmount.formattedCoin(),
                              hint: vm.needsSplitCount == 1 ? "1 coin" : "\(vm.needsSplitCount) coins")
                }
            }
            .padding(Theme.Space.x3)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

            feeTierPicker

            Text("A small network fee is deducted from the amount.",
                 bundle: .module, comment: "split coins fee note")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)

            if let error = vm.errorMessage {
                Text(error).textStyle(.sm).foregroundStyle(Theme.Colors.negative)
            }

            WalletButton(title: vm.isSplitting ? "Splitting…" : "Split coins") {
                Task { await vm.confirm() }
            }
            .disabled(vm.isSplitting)
            .opacity(vm.isSplitting ? 0.6 : 1)
            .padding(.top, Theme.Space.x2)
        }
    }

    private var successContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            Text("Your eCash is separated", bundle: .module, comment: "split coins success heading")
                .textStyle(.h1)
                .foregroundStyle(Theme.Colors.text0)
            Text("Your eCash has moved to a new address in this wallet. Spending it can no longer affect your Bitcoin.",
                 bundle: .module, comment: "split coins success body")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)
        }
    }

    // MARK: - Bits

    private var feeTierPicker: some View {
        Picker("Fee", selection: $vm.tier) {
            ForEach(SendViewModel.FeeTier.allCases, id: \.self) { tier in
                Text(tier.label).tag(tier)
            }
        }
        .pickerStyle(.segmented)
        .disabled(vm.isSplitting)
    }

    private func amountRow(labelKey: LocalizedStringKey, value: String, hint: String? = nil) -> some View {
        HStack {
            Text(labelKey, bundle: .module)
                .textStyle(.overline).foregroundStyle(Theme.Colors.text2)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: "\(value) \(vm.unitLabel)")
                    .font(.jbMono(15, .regular)).foregroundStyle(Theme.Colors.text0)
                if let hint {
                    Text(verbatim: hint).textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                }
            }
        }
    }
}
