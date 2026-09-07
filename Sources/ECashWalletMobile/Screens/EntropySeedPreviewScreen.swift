// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// SwiftUI only — `import Foundation` would make CGFloat ambiguous in the Fuse-Android pass.
import SwiftUI
import WalletService

/// The words the user's own entropy produced, shown **before** the wallet is created.
///
/// Only on the paranoid-mode path. The whole point of supplying your own randomness is being able to
/// see what it turned into: creating the wallet silently and revealing the phrase later would ask the
/// user to take our word for the one step they came here to check.
///
/// Nothing is persisted by this screen. The phrase is derived on the fly by the same
/// `EntropyDerivation` + `Mnemonic.fromEntropy` pair that will create the wallet — so what is shown is
/// exactly what gets made — and it is dropped when the screen goes (§8).
struct EntropySeedPreviewScreen: View {
    @Environment(AppState.self) var app

    let field: String
    let wordCount: Int
    /// Create the wallet from this field. The caller owns creation; this screen only previews.
    let onConfirm: (_ field: String, _ wordCount: Int) -> Void

    @State var words: [String] = []
    @State var error: String? = nil

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                Text("These words came from the entropy you provided. They are the wallet — write them down when you back up.",
                     bundle: .module, comment: "entropy seed preview explainer")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)

                if let error {
                    Text(verbatim: error)
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.negative)
                } else {
                    ScrollView { wordGrid }
                }

                Spacer()

                // Closes the audit loop. The user can hash the field they copied and check the result
                // against this before committing — without it, "verify for yourself" stops at copying
                // and they have to take the words on trust, which is the one thing this mode exists to
                // avoid.
                if let hex = EntropyDerivation.entropyHex(field: field, wordCount: wordCount) {
                    VStack(alignment: .leading, spacing: Theme.Space.x1) {
                        Text("Derived entropy — compare with your own shasum",
                             bundle: .module, comment: "audit comparison label")
                            .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                        Text(verbatim: hex)
                            .font(.jbMono(11, .regular))
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Theme.Space.x2)
                    .background(Theme.Colors.bg1)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }

                WalletButton(title: "Create wallet") {
                    onConfirm(field, wordCount)
                }
                .disabled(words.isEmpty)
                .opacity(words.isEmpty ? 0.6 : 1)
            }
            .padding(Theme.Space.gutter)
        }
        .navigationTitle(Text("Your recovery phrase", bundle: .module,
                              comment: "entropy seed preview title"))
        .onAppear { derive() }
        // Seed material must not outlive the screen (§8).
        .onDisappear { words = [] }
    }

    /// Two columns of numbered words — the same shape the Backup flow uses, so the phrase looks the
    /// same wherever the user meets it.
    private var wordGrid: some View {
        VStack(spacing: Theme.Space.x2) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: Theme.Space.x3) {
                    wordCell(index: row.left, word: words[row.left])
                    if let right = row.right {
                        wordCell(index: right, word: words[right])
                    } else {
                        Spacer()
                    }
                }
            }
        }
    }

    /// An Identifiable row — `ForEach` over a computed range renders nothing at all on Android.
    private struct WordRow: Identifiable {
        let id: Int
        let left: Int
        let right: Int?
    }

    private var rows: [WordRow] {
        var out: [WordRow] = []
        var index = 0
        while index < words.count {
            let right = index + 1 < words.count ? index + 1 : nil
            out.append(WordRow(id: index, left: index, right: right))
            index += 2
        }
        return out
    }

    private func wordCell(index: Int, word: String) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Text(verbatim: "\(index + 1)")
                .font(.jbMono(12, .regular))
                .foregroundStyle(Theme.Colors.text2)
                .frame(width: 22, alignment: .trailing)
            Text(verbatim: word)
                .font(.jbMono(15, .regular))
                .foregroundStyle(Theme.Colors.text0)
            Spacer()
        }
        .padding(.vertical, Theme.Space.x2)
        .padding(.horizontal, Theme.Space.x2)
        .background(Theme.Colors.bg1)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))
    }

    private func derive() {
        guard words.isEmpty else { return }
        if let phrase = app.previewEntropyMnemonic(field: field, wordCount: wordCount) {
            words = phrase.split(separator: " ").map { String($0) }
        } else {
            error = "Couldn't derive a phrase from that entropy."
        }
    }
}
