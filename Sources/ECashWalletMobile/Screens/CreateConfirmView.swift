// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The one interstitial in the create flow (Welcome → here → generate → Home). Sets the
/// self-custody expectation ("your keys, we can't recover them"), then generates the seed.
/// Backing up the phrase is deferred to the Backup flow — a nudge waits on Home (Slice 3).
///
/// All visuals are `Theme` tokens + shared components, so this is easy to restyle.
struct CreateConfirmView: View {
    let defaultName: String
    @Environment(AppState.self) var app
    @State var vm: CreateViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    // Default: eCash (alphanet). Changed from .signet 2026-08-28 — eCash is the network this app
    // exists for, and a signet default meant most users' first wallet was on the wrong chain.
    // Still never Bitcoin: mainnet stays a deliberate choice (Golden Rule §4).
    //
    // NOTE for whoever moves `.ecash` off the dry-run chain: the case follows the remote config,
    // which points at alphanet today (test value). When it rolls to real eCash mainnet, THIS LINE
    // silently becomes "default to real money" — revisit it then.
    @State var network: WalletNetwork = .ecash
    /// Routes what Continue does: straight to creation, or through the entropy flow first.
    ///
    /// **On by default.** Mixed mode is never weaker than taking the bits from the device alone — the
    /// CSPRNG still contributes its full 128/256 — so the only cost is a few seconds of the user's
    /// time, and the gain is a wallet that survives a compromised RNG.
    @State var useCustomEntropy = true

    init(viewModel: CreateViewModel, defaultName: String) {
        self.defaultName = defaultName
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Theme.Space.x5) {
                Spacer()

                // Network is chosen up front (it fixes the address set) and unmistakable (Golden Rule §4/§6).
                NetworkSelector(network: $network)

                // Advanced: pick the address type for the NEW wallet (a preference — a fresh seed has
                // no coins to match). Native segwit default. Hidden for Thunder (fixed ed25519 path).
                if network != .thunder { optionsSection }

                Text("Your keys, your coins", bundle: .module, comment: "create wallet heading")
                    .textStyle(.h1)
                    .foregroundStyle(Theme.Colors.text0)

                Text("This wallet lives only on this device. Your recovery phrase is the only way to restore it — not even we can recover it for you. You'll back it up right after.",
                     bundle: .module, comment: "create wallet self-custody explainer")
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text1)

                if let error = vm.errorMessage {
                    Text(error)
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.negative)
                        .padding(.top, Theme.Space.x1)
                }

                Spacer()

                // Two forms rather than one button with programmatic navigation: a NavigationLink
                // when the switch is on, a plain button when it isn't. Avoids `navigationDestination`,
                // which is unproven in SkipUI.
                if useCustomEntropy && network != .thunder {
                    NavigationLink {
                        EntropyOptionsScreen(wordCount: app.newWalletWordCount) { field, _ in
                            // Finish the job here: the user has done the work, so don't send them back
                            // to tap Continue a second time.
                            vm.entropyField = field
                            vm.submit(label: defaultName, network: network,
                                      wordCount: app.newWalletWordCount)
                        }
                    } label: {
                        Text("Continue", bundle: .module, comment: "continue to entropy")
                            .textStyle(.button)
                            .foregroundStyle(Theme.Colors.accentText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.x4)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(Theme.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    WalletButton(title: vm.isCreating ? "Creating…" : "Continue") {
                        // Seed length is a global setting (Settings → New wallets), not a per-create
                        // choice.
                        vm.submit(label: defaultName, network: network,
                                  wordCount: app.newWalletWordCount)
                    }
                    .disabled(vm.isCreating)
                    .opacity(vm.isCreating ? 0.6 : 1)
                }
            }
            .padding(Theme.Space.gutter)
        }
        .navigationTitle(Text("New wallet", bundle: .module, comment: "create wallet screen title"))
    }

    /// Address type, derivation and the paranoid-mode switch — **always visible**, not behind a
    /// disclosure. There are only three things here and they are the decisions worth seeing before
    /// making a wallet; hiding them under "Advanced" mostly hid them.
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            HStack {
                Text("Address type", bundle: .module, comment: "address type label")
                    .textStyle(.overline).foregroundStyle(Theme.Colors.text2)
                Spacer()
                Picker("Address type", selection: $vm.scriptType) {
                    ForEach(ScriptType.allCases, id: \.self) { type in
                        Text(verbatim: type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.Colors.accent)
            }

            HStack {
                Text("Derivation", bundle: .module, comment: "derivation path label")
                    .textStyle(.overline).foregroundStyle(Theme.Colors.text2)
                Spacer()
                Text(verbatim: derivationPath)
                    .font(.jbMono(13, .regular)).foregroundStyle(Theme.Colors.text1)
            }

            // A switch, not a link: it changes what Continue does rather than being a place to go.
            Toggle(isOn: $useCustomEntropy) {
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text("Provide your own entropy", bundle: .module,
                         comment: "paranoid mode toggle")
                        .textStyle(.body).foregroundStyle(Theme.Colors.text0)
                    Text("Add your own randomness to the device's. Takes a few seconds.",
                         bundle: .module, comment: "paranoid mode toggle explainer")
                        .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                }
            }
            .tint(Theme.Colors.accent)
        }
    }

    /// The account-level derivation path for the selected script type + network, e.g. `m/86'/0'/0'`.
    private var derivationPath: String {
        let coinType = NetworkRegistry.params(for: network).coinType
        return "m/\(vm.scriptType.purpose)'/\(coinType)'/0'"
    }
}
