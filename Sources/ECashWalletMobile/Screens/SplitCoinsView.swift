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
    @Environment(\.dismiss) var dismiss
    @State var vm: SplitViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var copied = false       // txid copy confirmation (not `private` — Fuse bridges @State)

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

    /// Success. The claim "your eCash is separated" is a big one to make about someone's money, so
    /// this shows the receipt behind it — what moved, what it cost, and the txid they can check on an
    /// explorer — and gives them a way out of the sheet. (Before, this was two lines of text on an
    /// otherwise blank screen with no dismiss affordance.)
    private var successContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            HStack(spacing: Theme.Space.x2) {
                Image(icon: Icon.check)
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(Theme.Colors.positive)
                Text("Your eCash is separated", bundle: .module, comment: "split coins success heading")
                    .textStyle(.h1)
                    .foregroundStyle(Theme.Colors.text0)
            }

            Text("Your eCash has moved to a new address in this wallet. Spending it can no longer affect your Bitcoin.",
                 bundle: .module, comment: "split coins success body")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)

            // The receipt. `vm.amount` is the pre-split spendable balance — what actually moved —
            // whereas the tx's own net effect is just the fee (it paid nobody but the miner).
            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                amountRow(labelKey: "Moved", value: vm.amount.formattedCoin())
                if let fee = vm.completedTx?.feeSats {
                    amountRow(labelKey: "Network fee", value: Amount(sats: fee).formattedCoin())
                }
            }
            .padding(Theme.Space.x3)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

            if let tx = vm.completedTx {
                VStack(alignment: .leading, spacing: Theme.Space.x2) {
                    HStack {
                        Text("TRANSACTION ID", bundle: .module, comment: "split success: txid header")
                            .textStyle(.overline)
                            .foregroundStyle(Theme.Colors.text2)
                        Spacer()
                        Button {
                            Clipboard.copy(tx.txid)
                            copied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                copied = false
                            }
                        } label: {
                            HStack(spacing: Theme.Space.x1) {
                                Image(icon: copied ? Icon.check : Icon.copy)
                                    .resizable().scaledToFit().frame(width: 13, height: 13)
                                (copied
                                    ? Text("Copied", bundle: .module, comment: "txid copied")
                                    : Text("Copy", bundle: .module, comment: "split success: copy txid"))
                                    .textStyle(.xs)
                            }
                            .foregroundStyle(copied ? Theme.Colors.positive : Theme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(verbatim: tx.txid)
                        .font(.jbMono(12, .regular))
                        .foregroundStyle(Theme.Colors.text0)

                    if let network = app.selectedWallet?.network,
                       let url = URL(string: RemoteServiceOverrides.explorerURL(for: tx.txid, on: network)) {
                        Link(destination: url) {
                            HStack(spacing: Theme.Space.x1) {
                                Text("View on block explorer", bundle: .module,
                                     comment: "split success: open block explorer")
                                    .textStyle(.sm)
                                Image(icon: Icon.send)   // north-east arrow = opens externally
                                    .resizable().scaledToFit().frame(width: 12, height: 12)
                            }
                            .foregroundStyle(Theme.Colors.accent)
                        }
                        .padding(.top, Theme.Space.x1)
                    }
                }
                .padding(Theme.Space.x3)
                .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }

            WalletButton(title: "Done") { dismiss() }
                .padding(.top, Theme.Space.x2)
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
