// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// SwiftUI only — `import Foundation` would make CGFloat ambiguous in the Fuse-Android pass.
import SwiftUI

/// The choices for paranoid mode, made **before** the input screen.
///
/// They used to live on the input screen itself, which put three segmented controls, a source picker,
/// the field, a meter, the grid and five buttons on one phone screen — too crammed to use, and the
/// keyboard covered the parts you needed to watch. Splitting them means the next screen can be nothing
/// but input (`docs/user-provided-entropy.md` §7).
///
/// These are also *set-and-forget* decisions: you pick them once, then you are in the input for as
/// long as it takes. Nothing here needs to be adjustable mid-swipe.
struct EntropyOptionsScreen: View {
    /// Called with the completed field once the user finishes the input step.
    let onComplete: (_ field: String, _ wordCount: Int) -> Void

    /// From Settings → New wallets. Shown here because it sets the target, but **not editable** —
    /// it stays a global preference rather than a per-create choice.
    let wordCount: Int
    @State var mode: EntropyMode = .mixed
    @State var method: EntropyInputMethod = .swipe
    @State var showDerivation = false

    init(wordCount: Int, onComplete: @escaping (_ field: String, _ wordCount: Int) -> Void) {
        self.wordCount = wordCount
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.x6) {
                    // Mode-dependent, because the honest thing to say differs completely between them
                    // — and with this now the DEFAULT path, a blanket "only use this if you know what
                    // you're doing" would be telling most users they shouldn't be here.
                    Text(mode == .mixed
                            ? "You'll add your own randomness on top of the device's. Whatever you produce, the wallet is at least as strong as a normal one — this only adds to it."
                            : "Nothing from this device goes in, so your input is the entire security of this wallet. The app cannot check how random it really is. Only use this if you understand what you're doing.",
                         bundle: .module, comment: "entropy mode explanation")
                        .textStyle(.sm)
                        .foregroundStyle(mode == .mixed ? Theme.Colors.text1 : Theme.Colors.warning)

                    // Seed length stays in Settings → New wallets. Surfaced here read-only because it
                    // sets how much input is required, but it is not a per-create decision.
                    HStack {
                        Text("Seed length", bundle: .module, comment: "seed length label")
                            .textStyle(.overline).foregroundStyle(Theme.Colors.text2)
                        Spacer()
                        Text(verbatim: "\(wordCount) words")
                            .textStyle(.sm).foregroundStyle(Theme.Colors.text1)
                    }

                    choice(title: "Where it comes from",
                           detail: mode == .mixed
                               ? "Your input, mixed with the device's randomness. Safe even if either one is bad."
                               : "Only what you provide. Nothing from this device goes in.") {
                        Picker("Source", selection: $mode) {
                            Text("Mixed", bundle: .module, comment: "entropy mode").tag(EntropyMode.mixed)
                            Text("Only mine", bundle: .module, comment: "entropy mode").tag(EntropyMode.userOnly)
                        }
                        .pickerStyle(.segmented)
                    }

                    choice(title: "How you'll enter it",
                           detail: method == .swipe
                               ? "Swipe around a grid of characters."
                               : "Type or paste something you generated elsewhere — dice, coin flips, anything.") {
                        Picker("Method", selection: $method) {
                            Text("Swipe", bundle: .module, comment: "entropy input method").tag(EntropyInputMethod.swipe)
                            Text("Type", bundle: .module, comment: "entropy input method").tag(EntropyInputMethod.typed)
                        }
                        .pickerStyle(.segmented)
                    }

                    Button {
                        showDerivation.toggle()
                    } label: {
                        Text("How this works", bundle: .module, comment: "entropy derivation disclosure")
                            .textStyle(.sm)
                    }
                    .tint(Theme.Colors.accent)

                    if showDerivation { derivationNote }
                }
                .padding(Theme.Space.gutter)
            }

            VStack {
                Spacer()
                NavigationLink {
                    EntropyInputScreen(wordCount: wordCount, mode: mode,
                                       method: method, onComplete: onComplete)
                } label: {
                    // Styled to match WalletButton's primary kind — that takes an action closure, so
                    // it can't wrap a NavigationLink's label directly.
                    // Named for what happens next, not "Continue" — the grid/keyboard lives on the
                    // following screen, and a bare "Continue" reads as if this screen is the whole
                    // feature.
                    Text(method == .swipe ? "Start swiping" : "Start typing",
                         bundle: .module, comment: "continue to entropy input")
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
                .padding(Theme.Space.gutter)
            }
        }
        .navigationTitle(Text("Your own entropy", bundle: .module, comment: "entropy screen title"))
    }

    private func choice<Control: View>(title: String, detail: String,
                                       @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text(verbatim: title)
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            control()
            Text(verbatim: detail)
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text1)
        }
    }

    /// The audit recipe. It lives here rather than on the input screen because it is something you read
    /// once, not something you consult while swiping. Quoting-proof: the alphabet contains `'`, `"`,
    /// `$` and backslash, so a naive `printf '%s' '…'` breaks on the first quote.
    private var derivationNote: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text("Your entropy is the visible string, hashed with SHA-256. Paste it into entropy.txt and check for yourself:",
                 bundle: .module, comment: "audit explanation")
                .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
            Text(verbatim: "printf '%s' \"$(cat entropy.txt)\" | shasum -a 256")
                .font(.jbMono(11, .regular))
                .foregroundStyle(Theme.Colors.text1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.x3)
        .background(Theme.Colors.bg1)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }
}
