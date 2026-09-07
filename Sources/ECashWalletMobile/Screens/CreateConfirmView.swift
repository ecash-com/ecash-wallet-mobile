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
    @State var advancedExpanded = false           // Advanced: derivation script type
    /// Set when the user completed the paranoid-mode screen — it owns the word count on that path.
    @State var entropyWordCount: Int? = nil

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
                if network != .thunder { advancedSection }

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

                WalletButton(title: vm.isCreating
                                ? "Creating…"
                                : "Continue") {
                    // Seed length is the global setting (Settings → New wallets) — EXCEPT on the
                    // paranoid-mode path, where the entropy screen owns it, because it sets the
                    // 128 vs 256-bit target and therefore how much work the user just did.
                    vm.submit(label: defaultName, network: network,
                              wordCount: entropyWordCount ?? app.newWalletWordCount)
                }
                .disabled(vm.isCreating)
                .opacity(vm.isCreating ? 0.6 : 1)
            }
            .padding(Theme.Space.gutter)
        }
        .navigationTitle(Text("New wallet", bundle: .module, comment: "create wallet screen title"))
    }

    /// Collapsed by default. The address-type picker for the new wallet — most users never touch it
    /// (native segwit); power users can pick Taproot etc. No live preview (the seed is generated at
    /// submit), just the derivation path.
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                Picker("Address type", selection: $vm.scriptType) {
                    ForEach(ScriptType.allCases, id: \.self) { type in
                        Text(verbatim: type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.Colors.accent)

                HStack {
                    Text("Derivation", bundle: .module, comment: "derivation path label")
                        .textStyle(.overline).foregroundStyle(Theme.Colors.text2)
                    Spacer()
                    Text(verbatim: derivationPath)
                        .font(.jbMono(13, .regular)).foregroundStyle(Theme.Colors.text1)
                }

                // Paranoid mode. Off by default and deliberately behind Advanced: the ordinary CSPRNG
                // path stays untouched for everyone who doesn't go looking for this.
                NavigationLink {
                    EntropyScreen(wordCount: entropyWordCount ?? app.newWalletWordCount) { field, words in
                        vm.entropyField = field
                        entropyWordCount = words
                    }
                } label: {
                    HStack(spacing: Theme.Space.x2) {
                        Text("Provide your own entropy", bundle: .module,
                             comment: "paranoid mode entry point")
                            .textStyle(.body).foregroundStyle(Theme.Colors.accent)
                        Spacer()
                        if vm.usesCustomEntropy {
                            Text("Ready", bundle: .module, comment: "custom entropy is set")
                                .textStyle(.xs).foregroundStyle(Theme.Colors.positive)
                        }
                        // A NavigationLink inside a DisclosureGroup renders as plain text with no
                        // chevron, so the row doesn't read as tappable without one of our own.
                        Image("chevron_right", bundle: .module)
                            .foregroundStyle(Theme.Colors.text2)
                    }
                }
            }
            .padding(.top, Theme.Space.x2)
        } label: {
            Text("Advanced", bundle: .module, comment: "advanced create options disclosure label")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)
        }
        .tint(Theme.Colors.accent)
    }

    /// The account-level derivation path for the selected script type + network, e.g. `m/86'/0'/0'`.
    private var derivationPath: String {
        let coinType = NetworkRegistry.params(for: network).coinType
        return "m/\(vm.scriptType.purpose)'/\(coinType)'/0'"
    }
}
