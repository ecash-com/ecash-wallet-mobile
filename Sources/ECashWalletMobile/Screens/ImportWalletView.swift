// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Restore a wallet from a 12/24-word recovery phrase (Welcome → here → Home). No network
/// question — same model as Create (`docs/wallet-and-network-model.md`). BDK validates the
/// word list + checksum at submit; a rejection shows only the scrubbed user message, never the
/// entered words (Golden Rule §2).
///
/// All visuals are `Theme` tokens + shared components. It shows a live seed; screenshots are NOT
/// blocked (the user's call), though the app-switcher snapshot is still obscured.
struct ImportWalletView: View {
    let defaultName: String
    @State var vm: ImportViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var walletName = ""
    // Default: eCash (alphanet). Changed from .signet 2026-08-28 — eCash is the network this app
    // exists for, and a signet default meant most users' first wallet was on the wrong chain.
    // Still never Bitcoin: mainnet stays a deliberate choice (Golden Rule §4).
    //
    // NOTE for whoever moves `.ecash` off the dry-run chain: the case follows the remote config,
    // which points at alphanet today (test value). When it rolls to real eCash mainnet, THIS LINE
    // silently becomes "default to real money" — revisit it then.
    @State var network: WalletNetwork = .ecash
    @State var advancedExpanded = false           // Advanced: import type (+ later, derivation path)

    // iOS-only keyboard ergonomics (focus advance + scroll-to-dismiss). Guarded so the Android
    // (Compose) transpile is untouched; the Skip docs sanction inline `#if os(iOS)` in a view.
    #if os(iOS)
    @FocusState private var focusedField: Field?
    private enum Field { case phrase, name }
    #endif

    /// - Parameters:
    ///   - claimMode: enter straight into the investor-claim flow — private-key input, with the
    ///     network picker and Advanced hidden entirely. Both paths default to eCash now, so this
    ///     only pins the import TYPE; a claimant was handed a key, not a recovery phrase.
    init(viewModel: ImportViewModel, defaultName: String, claimMode: Bool = false) {
        self.defaultName = defaultName
        viewModel.kind = claimMode ? .privateKey : .recoveryPhrase
        _vm = State(initialValue: viewModel)
        _network = State(initialValue: .ecash)
        _advancedExpanded = State(initialValue: claimMode)
        _isClaim = State(initialValue: claimMode)
    }

    /// Drives the claim-specific copy. Held as state rather than a `let` so the initializer above
    /// stays the single place the mode is decided.
    @State var isClaim = false

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()

            // ScrollView (not a fixed VStack): the on-screen keyboard would otherwise cover the
            // name field + Import button, and a large nav title only collapses correctly inside a
            // scroll view. Content scrolls clear of the keyboard; the button lives at the end.
            ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                if isClaim {
                    // Says what the key is, what will happen, and — the part that actually reassures
                    // — that importing only reads. Someone pasting a key from a letter is deciding
                    // whether to trust an app with it; "nothing moves" is the honest answer, since
                    // this derives an address and looks up a balance, and a send is a separate,
                    // confirmed action afterwards.
                    Text("Paste the private key from your investor letter. We'll show the balance it controls. Nothing moves until you choose to send.",
                         bundle: .module, comment: "investor claim explainer at top of the screen")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text1)
                }
                // A claim shows ONE input and nothing else. Everything below is a choice this user
                // doesn't have: the network is fixed (their coins are on eCash), the import type is
                // fixed (they were given a key, not a phrase), and the script type is fixed (a WIF
                // is a single key with no derivation). Showing a recovery-phrase control to someone
                // holding a private key invites them to paste it in the wrong box.
                if !isClaim {
                    // Network is chosen up front (it fixes the address set) and unmistakable
                    // (Golden Rule §4/§6).
                    NetworkSelector(network: $network)
                        .onChange(of: network) { _, newNet in
                            // Thunder has a fixed ed25519 derivation and no WIF/script-type concept
                            // — force the phrase path so a stale WIF/type selection can't carry over.
                            if newNet == .thunder { vm.kind = .recoveryPhrase }
                            vm.updatePreview(network: newNet)
                            vm.updateSeedPreview(network: newNet)
                        }

                    // Advanced (import type + BIP script-type derivation) applies only to
                    // BDK/secp256k1 networks. Thunder is ed25519 with a fixed derivation
                    // (m/1'/0'/0'/i') — no choice to make — so hide Advanced entirely for it.
                    if network != .thunder { advancedSection }
                }

                // Input depends on the chosen import type. In claim mode `kind` is pinned to
                // .privateKey by the initializer, so this is always the key field.
                if vm.kind == .privateKey {
                    privateKeyInput
                } else {
                    recoveryPhraseInput
                }

                // Optional name (labels are device-local; restoring a seed can't bring one back).
                // Hidden for a claim: one fewer decision, and the default name is fine — renaming
                // is a tap away in the wallet list afterwards.
                if !isClaim {
                TextField("Wallet name (optional — \"\(defaultName)\")", text: $walletName)
                    .textFieldStyle(.plain)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                    .autocorrectionDisabled()
                    .fieldBoxInset()
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    #if os(iOS)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.go)
                    .onSubmit { if vm.canSubmit { submitImport() } }
                    #endif
                }

                if let error = vm.errorMessage {
                    Text(error)
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.negative)
                }

                WalletButton(title: vm.isImporting
                                ? "Importing…"
                                : (isClaim ? "Claim"
                                   : (vm.kind == .privateKey ? "Import private key" : "Import wallet"))) {
                    submitImport()
                }
                .disabled(!vm.canSubmit)
                .opacity(vm.canSubmit ? 1 : 0.4)
                .padding(.top, Theme.Space.x2)
            }
            .padding(Theme.Space.gutter)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)   // swipe the content down to dismiss
            #endif
        }
        .navigationTitle(isClaim
            ? Text("Claim your ECX", bundle: .module, comment: "investor claim screen title")
            : Text("Import wallet", bundle: .module, comment: "import wallet screen title"))
        // Screenshots intentionally allowed (the user's call); app-switcher snapshot still obscured.
        .obscuredWhenBackgrounded()
    }

    // MARK: - Advanced options + input variants

    /// Collapsed by default. Holds the import-type toggle (recovery phrase vs private key) and, for a
    /// recovery phrase, the derivation script-type picker + live address preview (recovery-correctness
    /// for the airdrop — match the address kind the seed's coins live at).
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: Theme.Space.x3) {
                Picker("Import type", selection: $vm.kind) {
                    Text("Recovery phrase", bundle: .module, comment: "import type: 12/24-word seed phrase")
                        .tag(ImportViewModel.Kind.recoveryPhrase)
                    Text("Private key", bundle: .module, comment: "import type: single legacy WIF private key")
                        .tag(ImportViewModel.Kind.privateKey)
                }
                .pickerStyle(.segmented)
                .onChange(of: vm.kind) { _, _ in
                    vm.updatePreview(network: network)
                    vm.updateSeedPreview(network: network)
                }

                if vm.kind == .recoveryPhrase { derivationOptions }
            }
            .padding(.top, Theme.Space.x2)
        } label: {
            Text("Advanced", bundle: .module, comment: "advanced import options disclosure label")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)
        }
        .tint(Theme.Colors.accent)
    }

    /// Script-type picker + the resulting derivation path and first address — the guardrail for
    /// restoring a seed from another wallet ("match its address type"). Live preview updates as the
    /// user changes the script type, phrase, or network.
    private var derivationOptions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text("Restoring from another wallet? Match its address type.",
                 bundle: .module, comment: "custom derivation help")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)

            Picker("Address type", selection: $vm.scriptType) {
                ForEach(ScriptType.allCases, id: \.self) { type in
                    Text(verbatim: type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.Colors.accent)
            .onChange(of: vm.scriptType) { _, _ in vm.updateSeedPreview(network: network) }

            // Read-only derivation path (e.g. m/84'/0'/0') — the computed account path.
            HStack {
                Text("Derivation", bundle: .module, comment: "derivation path label")
                    .textStyle(.overline).foregroundStyle(Theme.Colors.text2)
                Spacer()
                Text(verbatim: derivationPath)
                    .font(.jbMono(13, .regular)).foregroundStyle(Theme.Colors.text1)
            }

            // Live first-address preview — appears once the phrase is a full valid mnemonic.
            if let addr = vm.seedPreviewAddress {
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text("First address", bundle: .module, comment: "derivation preview first address label")
                        .textStyle(.overline).foregroundStyle(Theme.Colors.text2)
                    Text(verbatim: addr)
                        .font(.jbMono(13, .regular)).foregroundStyle(Theme.Colors.text0)
                }
            }
        }
        .padding(Theme.Space.x3)
        .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    /// The account-level derivation path for the selected script type + network, e.g. `m/84'/0'/0'`.
    private var derivationPath: String {
        let coinType = NetworkRegistry.params(for: network).coinType
        return "m/\(vm.scriptType.purpose)'/\(coinType)'/0'"
    }

    /// The 12/24-word recovery-phrase input (the default import path).
    private var recoveryPhraseInput: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            Text("Enter your 12 or 24 word phrase, separated by spaces. It never leaves this device.",
                 bundle: .module, comment: "import wallet instructions")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)

            TextEditor(text: $vm.phrase)
                .textFieldStyle(.plain)   // clears Compose's amber focused-border ring (Android)
                .font(.jbMono(16, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .plainEditorBackground()
                .frame(minHeight: 140)
                .padding(Theme.Space.x2)
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
                .onChange(of: vm.phrase) { _, _ in
                    vm.phraseEdited()
                    vm.updateSeedPreview(network: network)
                }
                #if os(iOS)
                .focused($focusedField, equals: .phrase)
                #endif

            // Live word count — quiet guidance, no judgment until submit.
            Text(wordCountText, bundle: .module)
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    /// The legacy single-key (WIF) input + live address preview (Advanced → Private key).
    private var privateKeyInput: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            // Suppressed in claim mode: the screen already opens with a "paste the private key
            // from your investor letter" explainer, so this repeated the instruction and
            // reintroduced the jargon ("legacy", "WIF", "single-address wallet") that the claim
            // copy deliberately avoids.
            if !isClaim {
                Text("Paste a legacy private key (WIF). It becomes a single-address wallet on this device.",
                     bundle: .module, comment: "import private key instructions")
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text1)
            }

            TextField("Private key (WIF)", text: $vm.wif)
                .textFieldStyle(.plain)
                .font(.jbMono(15, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .fieldBoxInset()
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
                .onChange(of: vm.wif) { _, _ in vm.updatePreview(network: network) }

            // Live guardrail: show the address this key controls (or a hint once input is non-empty).
            if let addr = vm.previewAddress {
                VStack(alignment: .leading, spacing: Theme.Space.x1) {
                    Text("This key's address", bundle: .module, comment: "wif preview address label")
                        .textStyle(.overline)
                        .foregroundStyle(Theme.Colors.text2)
                    // Show the FULL address (best guardrail — the user verifies the whole thing).
                    // A legacy `1…` address is short and wraps cleanly. NOTE: `.truncationMode` is
                    // unavailable on Android (Skip), so don't reintroduce it here.
                    Text(verbatim: addr)
                        .font(.jbMono(14, .regular))
                        .foregroundStyle(Theme.Colors.text0)
                }
            } else if !vm.wif.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Not a valid private key for this network.",
                     bundle: .module, comment: "wif preview invalid hint")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
            }
        }
    }

    private func submitImport() {
        let trimmed = walletName.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.submit(label: trimmed.isEmpty ? defaultName : String(trimmed.prefix(24)), network: network)
    }

    private var wordCountText: LocalizedStringKey {
        let count = vm.wordCount
        if count == 0 { return "12 or 24 words" }
        if count == 1 { return "1 word" }
        return "\(count) words"
    }
}
