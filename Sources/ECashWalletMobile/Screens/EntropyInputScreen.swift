// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// SwiftUI only — `import Foundation` would make CGFloat ambiguous in the Fuse-Android pass.
import SwiftUI
import WalletService

/// Nothing but the input.
///
/// Every choice was made on the previous screen, so this one is three things: what you have produced
/// so far, how far along you are, and the surface you produce it with. That is the whole point of the
/// split — the earlier single-screen version had three segmented controls, a source picker, the field,
/// a meter, the grid and five buttons fighting for a phone screen.
///
/// **The two halves scroll differently, and that is deliberate.** Typed input must scroll, or the
/// keyboard covers the field and meter you need to watch. The swipe grid must NOT sit in a scrolling
/// container at all: SkipUI threads `_scrollAxes` into the Compose drag detector, so a scrolling
/// ancestor steals vertical swipes (§10).
struct EntropyInputScreen: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss

    let onComplete: (_ field: String, _ wordCount: Int) -> Void

    @State var vm: EntropyViewModel
    @State var layout: [Character] = EntropyAlphabet.shuffled()

    init(wordCount: Int, mode: EntropyMode, method: EntropyInputMethod,
         onComplete: @escaping (_ field: String, _ wordCount: Int) -> Void) {
        self.onComplete = onComplete
        let model = EntropyViewModel(wordCount: wordCount)
        model.mode = mode
        model.inputMethod = method
        _vm = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            if vm.inputMethod == .swipe { swipeLayout } else { typedLayout }
        }
        .navigationTitle(Text("Enter entropy", bundle: .module, comment: "entropy input screen title"))
        // Freeze the CSPRNG prefix + timestamp when the screen is actually shown — SwiftUI can build a
        // NavigationLink destination eagerly and fire onDisappear on it, which wiped them before the
        // user ever arrived.
        .onAppear { vm.beginSessionIfNeeded() }
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

    /// Scrolls, so the keyboard pushes the meter into view rather than burying it.
    ///
    /// **No separate "what you've produced" box here.** The editor already shows exactly that, and
    /// mirroring it above only asks the reader which of two identical boxes matters. The swipe path
    /// needs that display because the grid gives you nowhere else to see what you made.
    private var typedLayout: some View {
        VStack(spacing: Theme.Space.x3) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.x3) {
                    meter
                    livePhrase
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $vm.typedInput)
                            .textFieldStyle(.plain)
                            .font(.jbMono(14, .regular))
                            .foregroundStyle(Theme.Colors.text0)
                            .autocorrectionDisabled()
                            .noAutocapitalization()
                            // The app's helper — clears the editor's own opaque background so the
                            // Theme box below actually shows (CLAUDE.md §10).
                            .plainEditorBackground()
                            .frame(height: 220)
                            .fieldBoxInset()
                        if vm.typedInput.isEmpty {
                            Text("Type or paste your own random characters…",
                                 bundle: .module, comment: "typed entropy placeholder")
                                .font(.jbMono(14, .regular))
                                .foregroundStyle(Theme.Colors.text2)
                                .padding(Theme.Space.x4)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Theme.Colors.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

                    Button { vm.clear() } label: {
                        Text("Start over", bundle: .module, comment: "clear entropy input")
                            .textStyle(.sm)
                    }
                    .tint(Theme.Colors.accent)
                }
            }
            continueButton
        }
        .padding(Theme.Space.gutter)
    }

    // MARK: - Pieces

    /// What the grid has produced so far — swipe only, since the typed editor shows its own text.
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
                Text(verbatim: vm.userInput.isEmpty
                        ? "Swipe around the grid below…"
                        : vm.userInput)
                    .font(.jbMono(11, .regular))
                    .foregroundStyle(vm.userInput.isEmpty ? Theme.Colors.text2 : Theme.Colors.text0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .rotationEffect(.degrees(180))
            }
            .rotationEffect(.degrees(180))
            .frame(height: 84)
            Text(verbatim: "\(vm.userInput.count) characters")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    /// How far along you are, and the way out to an audit.
    private var meter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            ProgressView(value: vm.progress)
                .tint(vm.canContinue ? Theme.Colors.positive : Theme.Colors.accent)
            HStack {
                // Text only when there is something to act on. In the ordinary case the bar IS the
                // status — a number in bits invited comparison with a random number generator's, and
                // there is nothing useful to say beyond "keep going", which the bar already says.
                if let status = statusText {
                    Text(verbatim: status)
                        .textStyle(.xs)
                        .foregroundStyle(vm.canContinue ? Theme.Colors.positive : Theme.Colors.warning)
                }
                Spacer()
                Button { Clipboard.copy(vm.field) } label: {
                    Text("Copy", bundle: .module, comment: "copy the entropy field for auditing")
                        .textStyle(.xs)
                }
                .tint(Theme.Colors.accent)
            }
            // This count is an ESTIMATE from a model of how unpredictable swiping is — it is not the
            // same thing as bits from a random number generator, and showing a bare number in the same
            // units invites exactly that reading. Which mode you are in decides how much it matters.
            // Tell them what to DO. The earlier version explained why the number can't be trusted,
            // which is true but is not what someone staring at a half-full bar needs from it.
            Text(verbatim: instructionText)
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    /// Goes to the seed preview rather than creating: on this path the user came to see what their
    /// entropy produced, so creating silently and revealing the phrase afterwards would skip the one
    /// step they are here for.
    /// The words the current entropy would produce, updating live as the user swipes or types.
    ///
    /// Watching them churn is the point: it makes visible that every character is changing the wallet,
    /// which is otherwise an article of faith. They are dimmed until the gate passes, because until
    /// then they are a preview of a wallet the user should not actually make — the phrase is real and
    /// derivable at any length, and showing it undimmed would invite someone to write down words from
    /// two seconds of swiping.
    private var livePhrase: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text(vm.canContinue
                    ? "Your recovery phrase"
                    : "Recovery phrase so far — keeps changing as you go",
                 bundle: .module, comment: "live seed phrase label")
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            Text(verbatim: phrase.isEmpty ? "…" : phrase)
                // Deliberately small: at 24 words this wraps to about four lines, and the grid still
                // needs the room below it.
                .font(.jbMono(11, .regular))
                .foregroundStyle(vm.canContinue ? Theme.Colors.text0 : Theme.Colors.text2)
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

    // MARK: - Copy

    /// Says what is missing rather than just refusing — told only "keep going", a user assumes the
    /// feature is broken.
    ///
    /// **No bit counts.** Quoting "153/128 bits" put our figure in the same units as a random number
    /// generator's, which is exactly the false equivalence to avoid: a CSPRNG's 128 bits is a guarantee
    /// about a process, ours is a model of human behaviour. Showing progress without a number keeps
    /// the useful part (how far along you are) and drops the part that reads as a promise we cannot
    /// make.
    /// What to do, and — where it applies — the reassurance that the device is contributing too.
    private var instructionText: String {
        let action = vm.inputMethod == .swipe
            ? "Swipe over the box randomly for 10–15 seconds, or at least until the bar fills. The more the better."
            : "Type or paste your randomness — the more the better."
        if vm.mode == .mixed {
            return action + " It's also mixed with the device's randomness."
        }
        return action
    }

    private var statusText: String? {
        if vm.isRestoringFromPastedField {
            return "Restoring from a saved entropy string · \(vm.effectiveWordCount) words"
        }
        switch vm.rejection {
        case .none:
            return "Ready"
        case .some(.notEnoughBits):
            // Nothing to add — the bar is already saying "keep going". Typed input is the exception,
            // where a concrete count is genuinely useful.
            if vm.inputMethod == .typed {
                return "About \(vm.typedCharactersRemaining) more characters"
            }
            return nil
        case .some(.tooFewDistinctCharacters(let got, let want)):
            return "Use more variety — \(got)/\(want) different characters"
        case .some(.repetitivePattern):
            return "Too repetitive — vary it"
        }
    }
}
