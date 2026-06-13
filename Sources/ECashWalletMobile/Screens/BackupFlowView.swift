// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The Backup flow, presented full-screen from the Home warning or the Settings row:
/// intro gate → device auth → reveal (numbered word chips, capture-blocked) → verify
/// (3 random words, tap the right chip) → done. Success marks the wallet backed up, which
/// clears the Home warning. All visuals are `Theme` tokens.
struct BackupFlowView: View {
    @Environment(\.dismiss) var dismiss
    @State var vm: BackupViewModel   // not `private` — Fuse bridges @State (skip-fuse rule)

    init(viewModel: BackupViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.bg0.ignoresSafeArea()
                content
            }
            .navigationTitle("Back up")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if vm.step != .done {
                        Button { dismiss() } label: { Text("Cancel") }
                    }
                }
            }
        }
        // Block screen capture while the flow can show seed words (Android FLAG_SECURE; on,
        // then off when the flow leaves). iOS: obscured in the app switcher below.
        .onAppear { PlatformBridge.setSecureScreen(true) }
        .onDisappear {
            PlatformBridge.setSecureScreen(false)
            vm.wipe()
        }
        .obscuredWhenBackgrounded()
    }

    @ViewBuilder
    private var content: some View {
        switch vm.step {
        case .intro, .authenticating:
            intro
        case .reveal:
            reveal
        case .verify:
            verify
        case .done:
            done
        case .failed(let message):
            failed(message)
        }
    }

    // MARK: - Intro (the explicit gate)

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x5) {
            Spacer()
            Image(icon: Icon.backup)
                .resizable().scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.Colors.warning)
            Text("Your recovery phrase")
                .textStyle(.h1)
                .foregroundStyle(Theme.Colors.text0)
            Text("The next screen shows the words that control this wallet. "
                 + "Anyone who sees them can take your coins.")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)
            Text("Write them down on paper, in order. Don't screenshot them, "
                 + "don't store them in notes or the cloud.")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)
            Spacer()
            WalletButton(title: vm.step == .authenticating ? "Unlocking…" : "I understand — show me") {
                Task { await vm.begin() }
            }
            .disabled(vm.step == .authenticating)
            .opacity(vm.step == .authenticating ? 0.6 : 1)
        }
        .padding(Theme.Space.gutter)
    }

    // MARK: - Reveal (word chips)

    private var reveal: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            if vm.verifyMissed {
                Text("That wasn't quite right — check your copy against the words below.")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.negative)
            }
            Text("Write these \(vm.words.count) words down, in order.")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)

            wordGrid

            Spacer()

            WalletButton(title: "I've written them down") {
                vm.startVerify()
            }
        }
        .padding(Theme.Space.gutter)
    }

    /// Numbered chips, two per row. Plain fixed rows (no Lazy grids, no per-chip flexible
    /// children beyond the half-width frame) — the Android-stable layout shape.
    private var wordGrid: some View {
        VStack(spacing: Theme.Space.x2) {
            ForEach(0..<((vm.words.count + 1) / 2), id: \.self) { row in
                HStack(spacing: Theme.Space.x2) {
                    wordChip(index: row * 2)
                    if row * 2 + 1 < vm.words.count {
                        wordChip(index: row * 2 + 1)
                    }
                }
            }
        }
    }

    private func wordChip(index: Int) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Text("\(index + 1)")
                .font(.jbMono(12, .medium))
                .foregroundStyle(Theme.Colors.text2)
                .frame(width: 22, alignment: .trailing)
            Text(vm.words[index])
                .font(.jbMono(15, .medium))
                .foregroundStyle(Theme.Colors.text0)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.x2)
        .padding(.horizontal, Theme.Space.x3)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    // MARK: - Verify

    private var verify: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x5) {
            if let question = vm.currentQuestion {
                Text("Check \(vm.questionIndex + 1) of \(vm.questions.count)")
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
                Text("Which was word #\(question.wordIndex + 1)?")
                    .textStyle(.h2)
                    .foregroundStyle(Theme.Colors.text0)

                VStack(spacing: Theme.Space.x3) {
                    ForEach(question.choices, id: \.self) { choice in
                        Button {
                            vm.answer(choice)
                        } label: {
                            Text(choice)
                                .font(.jbMono(16, .medium))
                                .foregroundStyle(Theme.Colors.text0)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Space.x4)
                                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                                        .stroke(Theme.Colors.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
        }
        .padding(Theme.Space.gutter)
    }

    // MARK: - Terminal states

    private var done: some View {
        VStack(spacing: Theme.Space.x4) {
            Image(icon: Icon.check)
                .resizable().scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.Colors.positive)
            Text("Backed up")
                .textStyle(.h2)
                .foregroundStyle(Theme.Colors.text0)
            Text("Keep those words safe — they're the only way to restore this wallet.")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
                .multilineTextAlignment(.center)
            WalletButton(title: "Done") {
                dismiss()
            }
        }
        .padding(Theme.Space.gutter)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: Theme.Space.x4) {
            Image(icon: Icon.caution)
                .resizable().scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.Colors.negative)
            Text(message)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
                .multilineTextAlignment(.center)
            WalletButton(title: "Close") {
                dismiss()
            }
        }
        .padding(Theme.Space.gutter)
    }
}
