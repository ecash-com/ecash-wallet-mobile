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
    @State var network: WalletNetwork = .signet   // default to a testnet-class net; mainnet is deliberate

    // iOS-only keyboard ergonomics (focus advance + scroll-to-dismiss). Guarded so the Android
    // (Compose) transpile is untouched; the Skip docs sanction inline `#if os(iOS)` in a view.
    #if os(iOS)
    @FocusState private var focusedField: Field?
    private enum Field { case phrase, name }
    #endif

    init(viewModel: ImportViewModel, defaultName: String) {
        self.defaultName = defaultName
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()

            // ScrollView (not a fixed VStack): the on-screen keyboard would otherwise cover the
            // name field + Import button, and a large nav title only collapses correctly inside a
            // scroll view. Content scrolls clear of the keyboard; the button lives at the end.
            ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                // Network is chosen up front (it fixes the address set) and unmistakable (Golden Rule §4/§6).
                NetworkSelector(network: $network)

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
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    )
                    .onChange(of: vm.phrase) { _, _ in vm.phraseEdited() }
                    #if os(iOS)
                    .focused($focusedField, equals: .phrase)
                    #endif

                // Live word count — quiet guidance, no judgment until submit.
                Text(wordCountText, bundle: .module)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)

                // BitWindow keeps L1 funds under a derived "l1" seed, NOT the master phrase it shows
                // you — so the master imports cleanly but shows zero. Point users at the right phrase
                // (no derivation done here; see docs/bitwindow-import.md).
                bitWindowHint

                // Optional name (labels are device-local; restoring a seed can't bring one back).
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

                if let error = vm.errorMessage {
                    Text(error)
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.negative)
                }

                WalletButton(title: vm.isImporting
                                ? "Importing…"
                                : "Import wallet") {
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
        .navigationTitle(Text("Import wallet", bundle: .module, comment: "import wallet screen title"))
        // Screenshots intentionally allowed (the user's call); app-switcher snapshot still obscured.
        .obscuredWhenBackgrounded()
    }

    private func submitImport() {
        let trimmed = walletName.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.submit(label: trimmed.isEmpty ? defaultName : String(trimmed.prefix(24)), network: network)
    }

    /// Folded-by-default note for users coming from BitWindow: its on-screen "master" recovery phrase
    /// is NOT the seed that holds their coins — they need the wallet's derived "Bitcoin Core (Patched)"
    /// (l1) phrase, or the import succeeds with a zero balance.
    private var bitWindowHint: some View {
        DisclosureGroup {
            Text("BitWindow keeps your coins under a separate seed from the master recovery phrase it shows you. Import your wallet's phrase from your BitWindow backup — not the master phrase, which imports fine but shows no balance.",
                 bundle: .module, comment: "import: guidance for users coming from BitWindow")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Space.x2)
        } label: {
            Text("Importing from BitWindow?", bundle: .module, comment: "import: BitWindow guidance disclosure toggle")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
        }
        .tint(Theme.Colors.text2)
    }

    private var wordCountText: LocalizedStringKey {
        let count = vm.wordCount
        if count == 0 { return "12 or 24 words" }
        if count == 1 { return "1 word" }
        return "\(count) words"
    }
}
