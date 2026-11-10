// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// SwiftUI only — `import Foundation` would make CGFloat ambiguous in the Fuse-Android pass.
import SwiftUI
import WalletService

/// The step after the entropy grid: name the wallet, then create it.
///
/// This replaced a seed-preview screen (Jake, 2026-11-10). The grid already shows the words live,
/// at a readable size, as the user swipes — repeating them here was a second look at the same thing,
/// while the one decision the flow never offered was the wallet's name (it was always "Wallet N",
/// with a rename a few taps away in the list). So this screen asks for that instead.
///
/// The audit hook stays: the derived entropy hex and the recipe to reproduce it from the copied
/// field. It is not the phrase, and it is what lets a user check the derivation before committing
/// rather than taking the words on trust — the reason the entropy path exists.
///
/// Nothing is persisted here. The field is seed-equivalent and stays only as long as this screen;
/// creation is the caller's (`CreateWalletScreen` → `CreateViewModel`), which drops the field as
/// soon as the wallet exists (§8).
struct NameWalletScreen: View {
    let field: String
    let wordCount: Int
    /// What the field opens with ("Wallet 3"); also what an emptied field falls back to.
    let defaultName: String
    /// The create view model's error, if the last submit failed — this is the screen that submits.
    let errorMessage: String?
    /// Create the wallet. The caller owns creation; this screen only collects the name.
    let onConfirm: (_ field: String, _ wordCount: Int, _ label: String) -> Void

    @State var walletName = ""   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var copied = false

    // iOS-only keyboard ergonomics (Done dismisses). Guarded so the Android (Compose) transpile is
    // untouched; the Skip docs sanction inline `#if os(iOS)` in a view.
    //
    // The field is deliberately NOT focused on appear. Raising the keyboard while the push animation
    // is still running made "Use this entropy" feel sluggish on iOS (Jake, 2026-11-10), and the
    // default name is already a valid answer — the keyboard is for the user who taps to change it,
    // and it would otherwise cover the Create button for everyone else.
    #if os(iOS)
    @FocusState private var nameFocused: Bool
    #endif

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                Text("Names live only on this device — a recovery phrase can't bring one back. Pick whatever helps you tell your wallets apart; you can rename it later from the wallet list.",
                     bundle: .module, comment: "name wallet step explainer")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)

                nameField

                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.negative)
                }

                Spacer()

                auditBlock

                WalletButton(title: "Create wallet") {
                    onConfirm(field, wordCount, resolvedName)
                }
            }
            .padding(Theme.Space.gutter)
        }
        .navigationTitle(Text("Name your wallet", bundle: .module, comment: "name wallet step title"))
        .onAppear {
            if walletName.isEmpty { walletName = defaultName }
        }
    }

    // MARK: - Pieces

    /// Same box as the import screen's optional name, prefilled rather than placeholder-only: the
    /// user asked to be able to *change* the name, so the default is there to be edited over.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text("Wallet name", bundle: .module, comment: "name wallet step: field label")
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            TextField("", text: $walletName)
                .textFieldStyle(.plain)
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text0)
                .autocorrectionDisabled()
                .fieldBoxInset()
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                #if os(iOS)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
                #endif
        }
    }

    /// Closes the audit loop. The user can hash the field they copied and check the result against
    /// this before committing — without it, "verify for yourself" stops at copying and they have to
    /// take the derivation on trust, which is the one thing the entropy path exists to avoid.
    @ViewBuilder
    private var auditBlock: some View {
        if let hex = EntropyDerivation.entropyHex(field: field, wordCount: wordCount) {
            VStack(alignment: .leading, spacing: Theme.Space.x1) {
                Text("Derived entropy — compare with your own shasum",
                     bundle: .module, comment: "audit comparison label")
                    .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                Text(verbatim: hex)
                    .font(.jbMono(11, .regular))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Quoting-proof: the alphabet contains `'`, `"`, `$` and backslash, so
                // `printf '%s' '…'` breaks.
                Text(verbatim: "printf '%s' \"$(cat entropy.txt)\" | shasum -a 256")
                    .font(.jbMono(11, .regular))
                    .foregroundStyle(Theme.Colors.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The input to check, copyable right here next to the recipe that checks it.
                // Seed-equivalent, so sensitive: local-only, cleared after a minute.
                Button {
                    Clipboard.copySensitive(field)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        copied = false
                    }
                } label: {
                    if copied {
                        Text("Copied — clears in a minute", bundle: .module,
                             comment: "sensitive copy confirmation: clipboard is cleared after a minute")
                            .textStyle(.xs)
                    } else {
                        Text("Copy input", bundle: .module, comment: "copy the entropy field for auditing")
                            .textStyle(.xs)
                    }
                }
                .tint(Theme.Colors.accent)
                .padding(.top, Theme.Space.x1)
            }
            .padding(Theme.Space.x2)
            .background(Theme.Colors.bg1)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
    }

    // MARK: - Name

    /// Trimmed and capped like a rename (`AppState.renameWallet`); an emptied field means the default.
    private var resolvedName: String {
        let trimmed = walletName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : String(trimmed.prefix(24))
    }
}
