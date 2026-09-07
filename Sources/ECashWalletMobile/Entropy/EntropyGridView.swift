// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// SwiftUI only — adding `import Foundation` makes CGFloat/CGPoint ambiguous in the Fuse-Android pass
// ("'CGFloat' is ambiguous for type lookup"). Every other view in this app imports SwiftUI alone.
import SwiftUI

/// The swipe grid: 12 × 8 printable-ASCII keys the user drags across to supply entropy
/// (`docs/user-provided-entropy.md` §5).
///
/// **Why 12 columns is acceptable on a phone despite the 44pt touch-target rule (CLAUDE.md §8):**
/// there is no wrong cell. That minimum exists so people don't mis-tap the button they meant to hit;
/// here every cell the finger crosses is equally valid input, and a mis-hit *is* entropy. Denser cells
/// are in fact better — more transitions per unit of finger travel, so the target arrives sooner.
/// Legibility is the only real constraint.
///
/// **Two things the Android spike settled** (§10), both baked into this view:
/// - One `DragGesture(minimumDistance: 0)` over a `GeometryReader`-measured container, hit-testing
///   cells from local coordinates. Not per-cell gestures, and not `Canvas` (unsupported in SkipUI).
/// - **This must never sit inside a vertical `ScrollView`.** SkipUI threads `_scrollAxes` into the
///   Compose drag detector, so a scrolling ancestor steals vertical swipes and the user would scroll
///   the page instead of drawing entropy.
struct EntropyGridView: View {
    /// Characters in display order — shuffled, so the layout changes between sessions.
    let characters: [Character]
    let columns: Int
    let rows: Int
    /// Called for every sample. `startsGesture` marks the first sample after a touch-down.
    let onSample: (Character, Bool) -> Void

    /// The cell currently under the finger, highlighted like BitWindow's orange key.
    @State var activeIndex: Int? = nil
    /// Last cell a sample was emitted for, so a finger inside one cell doesn't spray samples.
    @State var lastEmittedIndex: Int? = nil
    @State var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let cellWidth = geometry.size.width / CGFloat(columns)
            let cellHeight = geometry.size.height / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                // A filled background is what makes the whole area hit-testable — `.contentShape()`
                // does not exist in SkipUI (spike finding, §10).
                Theme.Colors.bg1
                grid(cellWidth: cellWidth, cellHeight: cellHeight)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handle(location: value.location, cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                    .onEnded { _ in
                        isDragging = false
                        activeIndex = nil
                        lastEmittedIndex = nil
                    }
            )
        }
    }

    private func grid(cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        // Split into row/cell helpers with the arithmetic hoisted out: as one nested expression the
        // Android pass reported "unable to type-check this expression in reasonable time".
        VStack(spacing: 1) {
            ForEach(0..<rows, id: \.self) { row in
                gridRow(row: row, cellWidth: cellWidth, cellHeight: cellHeight)
            }
        }
    }

    private func gridRow(row: Int, cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        let width: CGFloat = cellWidth - 1
        let height: CGFloat = cellHeight - 1
        let base: Int = row * columns
        return HStack(spacing: 1) {
            ForEach(0..<columns, id: \.self) { column in
                cell(index: base + column, width: width, height: height)
            }
        }
    }

    private func cell(index: Int, width: CGFloat, height: CGFloat) -> some View {
        let isActive = activeIndex == index
        return ZStack {
            Rectangle()
                .fill(isActive ? Theme.Colors.accent : Theme.Colors.bg2)
            if index < characters.count {
                Text(verbatim: String(characters[index]))
                    .font(.jbMono(13, .regular))
                    .foregroundStyle(isActive ? Theme.Colors.accentText : Theme.Colors.text0)
            }
        }
        .frame(width: width, height: height)
    }

    /// Hit-test the touch point and emit a sample for **every** drag event, repeats included.
    ///
    /// **Emitting only on cell changes was wrong and silently disabled the dwell model.** Run lengths
    /// are what encode finger velocity — real motor and digitizer noise — and one-sample-per-cell makes
    /// every run length 1, so the accumulator's run-length credit never applied and the recorded string
    /// was not the faithful record §6.1 calls for.
    ///
    /// The "repeats will dominate" worry that motivated the old behaviour is already handled where it
    /// belongs: `EntropyAccumulator` caps a run at `maxRunSamples` and credits length once per run
    /// rather than per sample. A jittering fingertip therefore produces capped repeats, not free
    /// transitions — a transition can only occur when the cell actually changes.
    private func handle(location: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat) {
        guard cellWidth > 0, cellHeight > 0 else { return }
        var column = Int(location.x / cellWidth)
        var row = Int(location.y / cellHeight)
        if column < 0 { column = 0 }
        if column > columns - 1 { column = columns - 1 }
        if row < 0 { row = 0 }
        if row > rows - 1 { row = rows - 1 }
        let index = row * columns + column
        guard index < characters.count else { return }   // the two blank cells emit nothing

        activeIndex = index
        let startsGesture = !isDragging
        isDragging = true
        lastEmittedIndex = index
        onSample(characters[index], startsGesture)
    }
}

/// The 94 printable-ASCII characters the grid is built from, and its shuffled layouts.
///
/// Same set BitWindow uses, so the two implementations share an alphabet.
enum EntropyAlphabet {
    static let columns = 12
    static let rows = 8

    /// `!` (0x21) through `~` (0x7E) — every printable ASCII character except space. ASCII-only is
    /// deliberate: it removes Unicode normalisation entirely, so the same visible string can never
    /// derive different wallets on iOS and Android.
    static let characters: [Character] = {
        var out: [Character] = []
        for scalar in 0x21...0x7E {
            if let unicode = Unicode.Scalar(scalar) { out.append(Character(unicode)) }
        }
        return out
    }()

    /// A shuffled layout.
    ///
    /// **What shuffling buys: shoulder-surfing resistance.** With a fixed layout, anyone who films the
    /// user's finger recovers the string from the path alone; under a shuffled one the path is
    /// meaningless without the mapping, which is never displayed or recorded. It also breaks habit — a
    /// user who traces the same shape each time gets different characters.
    ///
    /// **What it does NOT buy: entropy.** The permutation comes from the CSPRNG, so if the CSPRNG is
    /// healthy the layout is unpredictable but the system/mixed modes already had their entropy — and
    /// if it is broken, which is the whole reason someone opens paranoid mode, the attacker knows the
    /// permutation. It can only help where help was not needed, so it is credited **zero bits**.
    static func shuffled() -> [Character] {
        var generator = SystemRandomNumberGenerator()
        return characters.shuffled(using: &generator)
    }
}
