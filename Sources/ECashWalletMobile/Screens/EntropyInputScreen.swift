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
    /// A real scroll view that follows the input: an anchor sits below the text and every change
    /// scrolls to it, so the newest characters are always in view and the text simply wraps normally.
    ///
    /// Two cleverer attempts came first and both looked wrong. Windowing by character made the block
    /// re-flow on every keystroke, so it appeared to slide left and be eaten from the start. Windowing
    /// by fixed-width line fixed that but needed a guessed pixel height, and the guess clipped the last
    /// line — hiding exactly the characters being watched. Scrolling is what was actually wanted.
    private var producedString: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: vm.userInput.isEmpty
                                ? "Swipe around the grid below…"
                                : vm.userInput)
                            .font(.jbMono(12, .regular))
                            .foregroundStyle(vm.userInput.isEmpty
                                ? Theme.Colors.text2 : Theme.Colors.text0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // The thing we scroll to. A zero-ish view below the text is the reliable
                        // anchor — scrolling to the Text itself lands on its top.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                    }
                }
                .frame(height: 104)
                .onChange(of: vm.userInput) { _, _ in
                    // No animation: this fires many times a second while swiping, and an animated
                    // scroll would never catch up.
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            // Always rendered, even at zero: appearing on the first character added a line and
            // visibly shrank the grid below.
            Text(verbatim: "\(vm.userInput.count) characters")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    private static let bottomAnchor = "entropy-tail"

    /// How far along you are, and the way out to an audit.
    private var meter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            ProgressView(value: vm.progress)
                .tint(vm.canContinue ? Theme.Colors.positive : Theme.Colors.accent)
            HStack {
                Text(verbatim: statusText)
                    .textStyle(.xs)
                    .foregroundStyle(vm.canContinue ? Theme.Colors.positive : Theme.Colors.text2)
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
            Text(vm.mode == .mixed
                    ? "An estimate, not a measurement — so we ask for double. Your input is also mixed with the device's randomness, so the wallet is at least as strong as a normal one either way."
                    : "An estimate, not a measurement — so we ask for double. With nothing mixed in this is all the wallet has, and it is not the same as bits from a random number generator.",
                 bundle: .module, comment: "entropy meter caveat")
                .textStyle(.xs)
                .foregroundStyle(vm.mode == .mixed ? Theme.Colors.text2 : Theme.Colors.warning)
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
    private var statusText: String {
        let bits = Int(vm.estimatedBits)
        let needed = Int(vm.requiredBits)
        if vm.isRestoringFromPastedField {
            return "Restoring from a saved entropy string · \(vm.effectiveWordCount) words"
        }
        switch vm.rejection {
        case .none:
            return "Ready · est. \(bits)/\(needed) bits"
        case .some(.notEnoughBits):
            if vm.inputMethod == .typed {
                return "est. \(bits)/\(needed) bits · about \(vm.typedCharactersRemaining) more"
            }
            return "est. \(bits)/\(needed) bits"
        case .some(.tooFewDistinctCharacters(let got, let want)):
            return "Use more variety — \(got)/\(want) different characters"
        case .some(.tooFewGestures(let got, let want)):
            return "Lift and swipe again — \(got)/\(want) strokes"
        case .some(.repetitivePattern):
            return "Too repetitive — vary it"
        }
    }
}
