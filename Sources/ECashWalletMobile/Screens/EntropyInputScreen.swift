// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// SwiftUI only — `import Foundation` would make CGFloat ambiguous in the Fuse-Android pass.
import SwiftUI
import WalletService

/// The create-wallet entropy step: swipe to add your own randomness to the device's.
///
/// Reached straight from New wallet — there are no options any more (always mixed, always swipe). The
/// input box opens prefilled with the device's random hex, and swipes are appended to it. "Use this
/// entropy" unlocks after a few seconds of swiping (`minimumBits`) — well short of a full bar, since
/// the device's randomness alone is a full-strength seed; the bar shows how much the user added.
///
/// The grid must NOT sit in a scrolling container: SkipUI threads `_scrollAxes` into the Compose drag
/// detector, so a scrolling ancestor steals vertical swipes (§10).
struct EntropyInputScreen: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss

    let onComplete: (_ field: String, _ wordCount: Int) -> Void

    @State var vm: EntropyViewModel
    @State var layout: [Character] = EntropyAlphabet.shuffled()
    @State var isEditing = false
    @State var editText = ""

    /// `model` comes from the session New wallet's Continue created, which already drew this session's
    /// device randomness and timestamp.
    init(model: EntropyViewModel, onComplete: @escaping (_ field: String, _ wordCount: Int) -> Void) {
        self.onComplete = onComplete
        _vm = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            swipeLayout
        }
        .navigationTitle(Text("Enter entropy", bundle: .module, comment: "entropy input screen title"))
        // Freeze the CSPRNG prefix + timestamp when the screen is actually shown — SwiftUI can build a
        // NavigationLink destination eagerly and fire onDisappear on it, which wiped them before the
        // user ever arrived.
        .onAppear { vm.beginSessionIfNeeded() }
        .sheet(isPresented: $isEditing) { editSheet }
        // NO `.onDisappear { vm.wipe() }`. It fires when the seed preview is pushed on TOP of this
        // screen, not only when the flow is left — so going forward to look at your words wiped them,
        // and coming back handed you a fresh session. A minute of swiping lost for having checked.
        //
        // Dropping it costs little: the view model is `@State`, so it is released when this screen is
        // popped, and an explicit wipe was never secure erasure anyway (Swift `String` gives no way to
        // zero its storage). The wipe on completion still runs — `CreateViewModel` clears the field as
        // soon as the wallet exists.
    }

    // MARK: - Layouts

    /// Fixed column: nothing here scrolls, so the grid keeps every drag it receives.
    private var swipeLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            producedString
            meter
            livePhrase
            EntropyGridView(characters: layout,
                            columns: EntropyAlphabet.columns,
                            rows: EntropyAlphabet.rows) { character, startsGesture in
                vm.recordSwipe(character, startsGesture: startsGesture)
            }
            // The grid takes whatever is left and may be squeezed — cells can be small here without
            // cost, because there is no wrong cell to mis-hit and denser cells actually yield more
            // transitions per unit of finger travel. The minimum just stops it collapsing at 24 words.
            .frame(minHeight: 200, maxHeight: .infinity)
            HStack {
                Button { layout = EntropyAlphabet.shuffled() } label: {
                    Text("Shuffle", bundle: .module, comment: "shuffle the entropy keyboard layout")
                }
                Spacer()
                Button { vm.clear() } label: {
                    Text("Start over", bundle: .module, comment: "clear entropy input")
                }
            }
            .textStyle(.sm)
            .tint(Theme.Colors.accent)
            continueButton
        }
        .padding(Theme.Space.gutter)
    }

    // MARK: - Pieces

    /// The whole hashed field: prefilled with version, word count, device randomness and timestamp,
    /// followed by what the grid has produced so far.
    ///
    /// **Bottom-anchored by rotating the scroll view, not by asking it to scroll.** SkipUI supports
    /// neither of the direct routes: `ScrollViewReader`/`scrollTo` compiles and is a silent no-op, and
    /// `.defaultScrollAnchor` / `.scrollIndicators` do not exist at all ("no member
    /// defaultScrollAnchor"). What it does support is `ScrollView` and `rotationEffect`.
    ///
    /// So the scroll view is turned 180° and its content turned back. The two rotations cancel
    /// visually — the text reads normally — but the scroll *axis* stays reversed, which makes the
    /// view's natural resting position (its "top") the bottom of the content. New characters therefore
    /// stay in view with no behaviour to depend on, on either platform, and the view is still a real
    /// scroll view you can drag back through.
    private var producedString: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            ScrollView {
                Text(verbatim: vm.displayedInput)
                    .font(.jbMono(11, .regular))
                    .foregroundStyle(Theme.Colors.text0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .rotationEffect(.degrees(180))
            }
            .rotationEffect(.degrees(180))
            .frame(height: 84)
            Text(verbatim: vm.userInput.isEmpty
                    ? "Swipe below to add your own randomness"
                    : "\(vm.userInput.count) swiped characters added")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    /// How far along you are, and the way out to an audit.
    private var meter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            ProgressView(value: vm.progress)
                .tint(meterColor)
            HStack {
                // Text only when there is something to act on. In the ordinary case the bar IS the
                // status — a number in bits invited comparison with a random number generator's, and
                // there is nothing useful to say beyond "keep going", which the bar already says.
                if let status = statusText {
                    Text(verbatim: status)
                        .textStyle(.xs)
                        .foregroundStyle(meterColor)
                }
                Spacer()
                Button {
                    editText = vm.field
                    isEditing = true
                } label: {
                    Text("Edit", bundle: .module, comment: "edit the entropy string by hand")
                        .textStyle(.xs)
                }
                .tint(Theme.Colors.accent)
                Button { Clipboard.copy(vm.field) } label: {
                    Text("Copy", bundle: .module, comment: "copy the entropy field for auditing")
                        .textStyle(.xs)
                }
                .tint(Theme.Colors.accent)
                .padding(.leading, Theme.Space.x3)
            }
            // This count is an ESTIMATE from a model of how unpredictable swiping is — it is not the
            // same thing as bits from a random number generator, and showing a bare number in the same
            // units invites exactly that reading.
            // Tell them what to DO. The earlier version explained why the number can't be trusted,
            // which is true but is not what someone staring at a half-full bar needs from it.
            Text(verbatim: instructionText)
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    /// The words the current entropy would produce, updating live as the user swipes.
    ///
    /// Watching them churn is the point: it makes visible that every character is changing the wallet,
    /// which is otherwise an article of faith. Dimmed until the bar fills — they will keep changing
    /// while the user is still swiping, so they aren't the words to write down yet. (The real words
    /// are shown, undimmed, on the preview screen.)
    private var livePhrase: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text(vm.isFull
                    ? "Your recovery phrase"
                    : "Recovery phrase so far — keeps changing as you go",
                 bundle: .module, comment: "live seed phrase label")
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            Text(verbatim: phrase.isEmpty ? "…" : phrase)
                // Deliberately small: at 24 words this wraps to about four lines, and the grid still
                // needs the room below it.
                .font(.jbMono(11, .regular))
                .foregroundStyle(vm.isFull ? Theme.Colors.text0 : Theme.Colors.text2)
                // Height reserved for the FULL phrase from the start. Otherwise the block grows from
                // one line to four as the words appear, and the grid visibly shrinks under it.
                .frame(maxWidth: .infinity, minHeight: reservedPhraseHeight,
                       alignment: .topLeading)
        }
        .padding(Theme.Space.x2)
        .background(Theme.Colors.bg1)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    /// Space set aside for the phrase, sized to the longest it can get at this word count — 12 words
    /// wrap to about three lines at 11pt mono, 24 to about five.
    private var reservedPhraseHeight: CGFloat {
        vm.effectiveWordCount == 24 ? 74 : 46
    }

    /// Derived through the same path that will create the wallet, so what is shown is what gets made.
    private var phrase: String {
        app.previewEntropyMnemonic(field: vm.field, wordCount: vm.effectiveWordCount) ?? ""
    }

    private var continueButton: some View {
        NavigationLink {
            // Goes to the seed preview rather than creating: the user sees the words before committing.
            EntropySeedPreviewScreen(field: vm.field, wordCount: vm.effectiveWordCount,
                                     onConfirm: onComplete)
        } label: {
            Text("Use this entropy", bundle: .module, comment: "continue to the seed preview")
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
        .disabled(!vm.canContinue)
        .opacity(vm.canContinue ? 1 : 0.6)
    }

    // MARK: - Edit

    /// The whole string in a text editor — paste a saved one to reproduce its wallet, or change it to
    /// test. Saved as written (`EntropyViewModel.applyEdit`); the swipe minimum doesn't apply to it.
    private var editSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.x3) {
                Text("This is exactly what gets hashed. Paste a saved string to get the same wallet again.",
                     bundle: .module, comment: "entropy edit sheet explanation")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
                TextEditor(text: $editText)
                    .textFieldStyle(.plain)
                    .font(.jbMono(13, .regular))
                    .foregroundStyle(Theme.Colors.text0)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                    .plainEditorBackground()
                    .fieldBoxInset()
                    .frame(maxHeight: .infinity)
                    .background(Theme.Colors.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .padding(Theme.Space.gutter)
            .background(Theme.Colors.bg0)
            .navigationTitle(Text("Edit entropy", bundle: .module, comment: "entropy edit sheet title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CloseToolbarButton { isEditing = false } }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmToolbarButton {
                        vm.applyEdit(editText)
                        isEditing = false
                    }
                }
            }
        }
    }

    // MARK: - Copy

    /// What to do, and the reassurance that the device is contributing too.
    private var instructionText: String {
        "Swipe over the box randomly for a few seconds to continue, or until the bar fills. The more the better — it's mixed with the device's randomness."
    }

    /// Red until the minimum swiping (the button is still off), amber once it can continue, green
    /// when the bar is full.
    private var meterColor: Color {
        if vm.isEdited { return vm.canContinue ? Theme.Colors.positive : Theme.Colors.negative }
        if !vm.hasMinimumInput { return Theme.Colors.negative }
        if !vm.isFull { return Theme.Colors.warning }
        return Theme.Colors.positive
    }

    /// Says what is missing rather than just a stuck bar — told only "keep going", a user assumes the
    /// feature is broken.
    ///
    /// **No bit counts.** Quoting "153/128 bits" put our figure in the same units as a random number
    /// generator's, which is exactly the false equivalence to avoid: a CSPRNG's 128 bits is a guarantee
    /// about a process, ours is a model of human behaviour.
    private var statusText: String? {
        if vm.isEdited {
            return vm.canContinue
                ? "Using your edited string · \(vm.effectiveWordCount) words"
                : "Must start with v1&12& or v1&24&"
        }
        switch vm.rejection {
        case .none:
            return "Plenty — nice work"
        case .some(.notEnoughBits):
            // Below the minimum, say why the button is still off; past it, nudge toward a full bar.
            return vm.hasMinimumInput ? "That'll do… but why stop?"
                                      : "Keep swiping to continue"
        case .some(.tooFewDistinctCharacters(let got, let want)):
            return "Use more variety — \(got)/\(want) different characters"
        case .some(.repetitivePattern):
            return "Too repetitive — vary it"
        }
    }
}
