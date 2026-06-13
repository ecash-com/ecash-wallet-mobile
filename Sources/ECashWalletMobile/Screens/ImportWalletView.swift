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
/// All visuals are `Theme` tokens + shared components. Capture-blocked like the Backup reveal
/// (FLAG_SECURE on Android, obscured-when-backgrounded on iOS) — it shows a live seed.
struct ImportWalletView: View {
    let defaultName: String
    @State var vm: ImportViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var walletName = ""

    init(viewModel: ImportViewModel, defaultName: String) {
        self.defaultName = defaultName
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                // Network identity, up front and unmistakable (Golden Rule §6).
                NetworkBadge(name: "Signet", isMainnet: false)

                Text("Restore from recovery phrase")
                    .textStyle(.h1)
                    .foregroundStyle(Theme.Colors.text0)

                Text("Enter your 12 or 24 word phrase, separated by spaces. "
                     + "It never leaves this device.")
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text1)

                TextEditor(text: $vm.phrase)
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

                // Live word count — quiet guidance, no judgment until submit.
                Text(wordCountText)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)

                // Optional name (labels are device-local; restoring a seed can't bring one back).
                TextField("Wallet name (optional — \"\(defaultName)\")", text: $walletName)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                    .autocorrectionDisabled()
                    .padding(Theme.Space.x3)
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

                if let error = vm.errorMessage {
                    Text(error)
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.negative)
                }

                Spacer()

                WalletButton(title: vm.isImporting ? "Importing…" : "Import wallet") {
                    let trimmed = walletName.trimmingCharacters(in: .whitespacesAndNewlines)
                    vm.submit(label: trimmed.isEmpty ? defaultName : String(trimmed.prefix(24)),
                              network: .signet)
                }
                .disabled(!vm.canSubmit)
                .opacity(vm.canSubmit ? 1 : 0.4)
            }
            .padding(Theme.Space.gutter)
        }
        .navigationTitle("Import wallet")
        .onAppear { PlatformBridge.setSecureScreen(true) }
        .onDisappear { PlatformBridge.setSecureScreen(false) }
        .obscuredWhenBackgrounded()
    }

    private var wordCountText: String {
        let count = vm.wordCount
        if count == 0 { return "12 or 24 words" }
        if count == 1 { return "1 word" }
        return "\(count) words"
    }
}
