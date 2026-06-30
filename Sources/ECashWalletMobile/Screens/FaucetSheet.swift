// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Signet faucet sheet: requests valueless test coins to the wallet's next unused receive address.
/// Leads with a clear "play money, no real value" notice (these are test coins). One tap to request;
/// shows the resulting txid on success, or the faucet's message (e.g. rate-limit) on failure.
///
/// No `NavigationStack`/toolbar (it would render a Material top app bar on Android) — swipe-to-dismiss
/// plus the footer button (CLAUDE.md §10 sheet-chrome rule).
struct FaucetSheet: View {
    @State var viewModel: FaucetViewModel   // not `private` — Fuse bridges @State (skip-fuse rule)
    @Environment(\.dismiss) var dismiss

    init(viewModel: FaucetViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: Theme.Space.x5) {
                        header
                        playMoneyNotice
                        if isOnCooldown {
                            cooldownNotice
                        } else {
                            amountLine
                        }
                        resultView
                    }
                    .padding(Theme.Space.gutter)
                }
                .scrollIndicators(.hidden)
                footer
            }
        }
        // A successful dispense closes the sheet (the wallet re-syncs behind it, so the incoming
        // coins show up as pending on Home — that's the confirmation).
        .onChange(of: viewModel.state) { _, newState in
            if case .success = newState { dismiss() }
        }
    }

    private var isOnCooldown: Bool {
        if case .cooldown = viewModel.state { return true }
        return false
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Space.x3) {
            // Signet color (violet) — this is a testnet-only faucet, so the glyph matches the
            // network's chip color rather than the brand accent.
            ZStack {
                Circle().fill(Theme.Colors.netTestnet.opacity(0.15))
                Image(icon: Icon.faucet)
                    .resizable().scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Theme.Colors.netTestnet)
            }
            .frame(width: 64, height: 64)

            Text("Get signet coins", bundle: .module, comment: "faucet sheet title")
                .textStyle(.h1)
                .foregroundStyle(Theme.Colors.text0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x6)
    }

    // MARK: - Play-money notice

    private var playMoneyNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("Test coins — no real value", bundle: .module, comment: "faucet play-money notice title")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
            Text("These are signet test coins for trying out the wallet. They're play money: they can't be sold or spent anywhere real, and they're worth nothing.",
                 bundle: .module, comment: "faucet play-money notice body")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.x4)
        .background(Theme.Colors.warningTint, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.warning.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Amount

    private var amountLine: some View {
        Text("We'll send \(viewModel.amountText) \(viewModel.unitLabel) to your wallet.",
             bundle: .module, comment: "faucet: amount explainer; %@ are amount + unit")
            .textStyle(.sm)
            .foregroundStyle(Theme.Colors.text1)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Cooldown

    private var cooldownNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            HStack(spacing: Theme.Space.x2) {
                Image(icon: Icon.pending)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.Colors.text1)
                Text("You already grabbed coins", bundle: .module, comment: "faucet cooldown title")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)
            }
            Text("Give it a little while before requesting more — try again in \(viewModel.cooldownText).",
                 bundle: .module, comment: "faucet cooldown body; %@ is a duration like \"42 minutes\"")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.x4)
        .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: - Result (success / failure)

    @ViewBuilder
    private var resultView: some View {
        switch viewModel.state {
        case .failed(let message):
            HStack(spacing: Theme.Space.x2) {
                Image(icon: Icon.caution)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.Colors.negative)
                Text(verbatim: message)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.negative)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.x4)
            .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

        default:
            EmptyView()
        }
    }

    // MARK: - Footer button

    @ViewBuilder
    private var footer: some View {
        Group {
            switch viewModel.state {
            case .cooldown, .success:
                // Cooldown → just close. Success briefly hits this state before `.onChange` dismisses.
                WalletButton(title: "Close", kind: .secondary) { dismiss() }
            case .requesting:
                // Disabled, with a spinner, while the request is in flight.
                HStack(spacing: Theme.Space.x2) {
                    ProgressView()
                    Text("Requesting…", bundle: .module, comment: "faucet request in progress")
                        .textStyle(.button)
                        .foregroundStyle(Theme.Colors.accentText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.x4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.accent.opacity(0.6)))
            default:
                // idle / failed → request (failed shows "Try again")
                WalletButton(title: isFailed ? "Try again" : "Get coins") {
                    Task { await viewModel.request() }
                }
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.bottom, Theme.Space.x4)
    }

    private var isFailed: Bool {
        if case .failed = viewModel.state { return true }
        return false
    }
}
