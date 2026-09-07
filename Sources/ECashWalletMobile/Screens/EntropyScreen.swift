// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// "Paranoid mode": the user supplies their own entropy instead of taking it from the OS CSPRNG
/// (`docs/user-provided-entropy.md`).
///
/// **The layout is constrained by the drag gesture, not by taste.** The grid must not sit inside a
/// scrolling container — SkipUI threads `_scrollAxes` into the Compose drag detector, so a scrolling
/// ancestor would steal vertical swipes and scroll the page instead of drawing entropy (§10). So the
/// screen is a fixed column: controls and a scrollable field on top, grid pinned below, and only the
/// field itself scrolls.
struct EntropyScreen: View {
    @Environment(\.dismiss) var dismiss

    /// Called with the completed field once the user accepts it. The caller creates the wallet — this
    /// screen never touches the wallet store.
    let onComplete: (_ field: String, _ wordCount: Int) -> Void

    @State var vm: EntropyViewModel
    @State var layout: [Character] = EntropyAlphabet.shuffled()
    @State var showDerivation = false

    init(wordCount: Int, onComplete: @escaping (_ field: String, _ wordCount: Int) -> Void) {
        self.onComplete = onComplete
        _vm = State(initialValue: EntropyViewModel(wordCount: wordCount))
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Space.x3) {
                warning
                controls
                fieldBox
                meter
                if vm.inputMethod == .swipe { gridSection } else { typedSection }
                actions
            }
            .padding(Theme.Space.gutter)
        }
        .navigationTitle(Text("Your own entropy", bundle: .module, comment: "entropy screen title"))
        // Freeze the CSPRNG prefix + timestamp when the screen is actually shown. Not in `init`:
        // SwiftUI may build this destination eagerly and then fire `onDisappear` on it, wiping the
        // components before the user arrives.
        .onAppear { vm.beginSessionIfNeeded() }
        // Seed-equivalent material must not outlive the screen (§8).
        .onDisappear { vm.wipe() }
    }

    // MARK: - Sections

    private var warning: some View {
        Text("A weak string makes a weak wallet, and the app cannot check your randomness for you. Only use this if you understand what you're doing.",
             bundle: .module, comment: "paranoid mode warning")
            .textStyle(.sm)
            .foregroundStyle(Theme.Colors.warning)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Picker("Seed length", selection: $vm.wordCount) {
                Text(verbatim: "12 words").tag(12)
                Text(verbatim: "24 words").tag(24)
            }
            .pickerStyle(.segmented)

            Picker("Source", selection: $vm.mode) {
                Text("Mixed", bundle: .module, comment: "entropy mode").tag(EntropyMode.mixed)
                Text("Mine only", bundle: .module, comment: "entropy mode").tag(EntropyMode.userOnly)
            }
            .pickerStyle(.segmented)

            Picker("Method", selection: $vm.inputMethod) {
                Text("Swipe", bundle: .module, comment: "entropy input method").tag(EntropyInputMethod.swipe)
                Text("Type", bundle: .module, comment: "entropy input method").tag(EntropyInputMethod.typed)
            }
            .pickerStyle(.segmented)
        }
    }

    /// The field is the input, and showing all of it is what makes the derivation auditable — the user
    /// hashes exactly this. It runs to a few hundred characters, so it scrolls, and it gets a Copy
    /// button rather than `.textSelection` (which is iOS-only — it fails the Android pass — and would
    /// be a poor way to lift 260 characters anyway).
    private var fieldBox: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.x1) {
            fieldText
            Button {
                Clipboard.copy(vm.field)
            } label: {
                Text("Copy", bundle: .module, comment: "copy the entropy field for auditing")
                    .textStyle(.xs)
            }
            .tint(Theme.Colors.accent)
        }
    }

    private var fieldText: some View {
        ScrollView {
            Text(verbatim: vm.field)
                .font(.jbMono(11, .regular))
                .foregroundStyle(Theme.Colors.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 84)
        .padding(Theme.Space.x2)
        .background(Theme.Colors.bg2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            ProgressView(value: vm.progress)
                .tint(vm.canContinue ? Theme.Colors.positive : Theme.Colors.accent)
            Text(verbatim: statusText)
                .textStyle(.xs)
                .foregroundStyle(vm.canContinue ? Theme.Colors.positive : Theme.Colors.text2)
        }
    }

    private var gridSection: some View {
        EntropyGridView(characters: layout,
                        columns: EntropyAlphabet.columns,
                        rows: EntropyAlphabet.rows) { character, startsGesture in
            vm.recordSwipe(character, startsGesture: startsGesture)
        }
        .frame(maxHeight: .infinity)
    }

    private var typedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Picker("Kind", selection: $vm.typedSource) {
                Text("Dice", bundle: .module, comment: "typed entropy source").tag(TypedEntropySource.diceD6)
                Text("Coin", bundle: .module, comment: "typed entropy source").tag(TypedEntropySource.coinFlip)
                Text("Hex", bundle: .module, comment: "typed entropy source").tag(TypedEntropySource.hex)
                Text("Text", bundle: .module, comment: "typed entropy source").tag(TypedEntropySource.freeText)
            }
            .pickerStyle(.segmented)

            Text(verbatim: typedHint)
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)

            TextEditor(text: $vm.typedInput)
                .textFieldStyle(.plain)
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .frame(maxHeight: .infinity)
                .fieldBoxInset()
                .background(Theme.Colors.bg2)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Space.x2) {
            HStack(spacing: Theme.Space.x2) {
                Button {
                    layout = EntropyAlphabet.shuffled()
                } label: {
                    Text("Shuffle", bundle: .module, comment: "shuffle the entropy keyboard layout")
                }
                .disabled(vm.inputMethod != .swipe)
                Spacer()
                Button {
                    vm.clear()
                } label: {
                    Text("Clear", bundle: .module, comment: "clear entropy input")
                }
                Spacer()
                Button {
                    showDerivation.toggle()
                } label: {
                    Text("How this works", bundle: .module, comment: "entropy derivation disclosure")
                }
            }
            .textStyle(.sm)
            .tint(Theme.Colors.accent)

            if showDerivation { derivationDisclosure }

            WalletButton(title: "Use this entropy") {
                onComplete(vm.field, vm.wordCount)
            }
            .disabled(!vm.canContinue)
            .opacity(vm.canContinue ? 1 : 0.6)
        }
    }

    /// The audit recipe, in the UI rather than only in docs — being checkable is the entire point of
    /// this mode. Quoting-proof on purpose: the alphabet contains `'`, `"`, `$` and backslash, so a
    /// naive `printf '%s' '…'` breaks the moment the user's string contains a quote.
    private var derivationDisclosure: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text("Paste the field into entropy.txt, then run:",
                 bundle: .module, comment: "audit instructions")
                .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
            Text(verbatim: "printf '%s' \"$(cat entropy.txt)\" | shasum -a 256")
                .font(.jbMono(11, .regular))
                .foregroundStyle(Theme.Colors.text1)
            if let hex = vm.entropyHex {
                Text("The first characters should match:", bundle: .module, comment: "audit comparison")
                    .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                Text(verbatim: hex)
                    .font(.jbMono(11, .regular))
                    .foregroundStyle(Theme.Colors.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.x2)
        .background(Theme.Colors.bg1)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    // MARK: - Copy

    /// Deliberately says what is missing rather than just refusing — a user told "keep going" with no
    /// target assumes the feature is broken.
    private var statusText: String {
        let bits = Int(vm.estimatedBits)
        let needed = Int(vm.requiredBits)
        switch vm.rejection {
        case .none:
            return "Ready · \(bits)/\(needed) bits"
        case .some(.notEnoughBits):
            return "\(bits)/\(needed) bits"
        case .some(.tooFewDistinctCharacters(let got, let want)):
            return "Use more of the grid — \(got)/\(want) different keys"
        case .some(.tooFewGestures(let got, let want)):
            return "Lift and swipe again — \(got)/\(want) strokes"
        case .some(.repetitivePattern):
            return "Too repetitive — vary it"
        }
    }

    private var typedHint: String {
        let needed = vm.typedSource.requiredCharacters(forBits: vm.requiredBits)
        let remaining = vm.typedCharactersRemaining
        switch vm.typedSource {
        case .diceD6: return "Enter \(needed) dice rolls (1–6) · \(remaining) to go"
        case .coinFlip: return "Enter \(needed) coin flips (0/1) · \(remaining) to go"
        case .hex: return "Enter \(needed) hex characters · \(remaining) to go"
        case .freeText: return "Enter \(needed) characters · \(remaining) to go"
        }
    }
}
