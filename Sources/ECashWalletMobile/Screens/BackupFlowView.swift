// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The Backup flow, presented full-screen from the Home warning or the Settings row:
/// intro gate → device auth → reveal (numbered word chips) → verify
/// (3 random words, tap the right chip) → done. Success marks the wallet backed up, which
/// clears the Home warning. All visuals are `Theme` tokens.
struct BackupFlowView: View {
    @Environment(\.dismiss) var dismiss
    @State var vm: BackupViewModel   // not `private` — Fuse bridges @State (skip-fuse rule)
    @State var understood = false     // the "I understand…" acknowledgement gate on the intro
    @State var scamsExpanded = false  // the "Common scams" disclosure (folded by default)

    init(viewModel: BackupViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.bg0.ignoresSafeArea()
                content
            }
            // Name the wallet being backed up — secrets are per-wallet.
            .navigationTitle(vm.isPrivateKey
                ? Text("\(vm.walletLabel) private key", bundle: .module, comment: "backup flow title (private key); %@ is the wallet name")
                : Text("\(vm.walletLabel) recovery phrase", bundle: .module, comment: "backup flow title; %@ is the wallet name"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if vm.step != .done {
                        CloseToolbarButton { dismiss() }
                    }
                }
            }
        }
        // Screenshots are intentionally NOT blocked on the seed screens — it's the user's call
        // whether to capture their recovery phrase. We still wipe the in-memory phrase when the flow
        // leaves; the app-switcher snapshot stays obscured (that's privacy, not a screenshot block).
        .onDisappear { vm.wipe() }
        .obscuredWhenBackgrounded()
    }

    @ViewBuilder
    private var content: some View {
        switch vm.step {
        case .intro, .authenticating:
            intro
        case .reveal:
            if vm.isPrivateKey { privateKeyReveal } else { mnemonicReveal }
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
        // Scrollable warning content above; the acknowledgement + Continue stay pinned at the bottom.
        // (`safeAreaInset` is unavailable in SkipUI, so we use a VStack { ScrollView; controls }.)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.Space.x5) {
                    (vm.isPrivateKey
                        ? Text("Keep your private key secret", bundle: .module, comment: "backup intro heading (private key)")
                        : Text("Keep your recovery phrase secret", bundle: .module, comment: "backup intro heading"))
                        .textStyle(.h1)
                        .foregroundStyle(Theme.Colors.text0)
                        .multilineTextAlignment(.center)
                        .padding(.top, Theme.Space.x4)

                    VStack(alignment: .leading, spacing: Theme.Space.x4) {
                        infoBullet(Icon.key,
                                   vm.isPrivateKey
                                   ? Text("This private key is the only key to this wallet — whoever has it controls the coins.",
                                          bundle: .module, comment: "backup intro point: master key (private key)")
                                   : Text("These words are the only key to this wallet — whoever has them controls the coins.",
                                          bundle: .module, comment: "backup intro point: master key"))
                        infoBullet(Icon.hide,
                                   Text("Anyone who sees them can drain the wallet, and no one can reverse it or get the coins back.",
                                        bundle: .module, comment: "backup intro point: theft is irreversible"))
                        infoBullet(Icon.backup,
                                   Text("We'll never ask for them. Don't type them into any site, app, or message.",
                                        bundle: .module, comment: "backup intro point: never share"))
                    }

                    commonScams
                }
                .padding(Theme.Space.gutter)
            }

            // Pinned acknowledgement gate + Continue.
            VStack(spacing: Theme.Space.x4) {
                Button { understood.toggle() } label: {
                    HStack(alignment: .top, spacing: Theme.Space.x3) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(understood ? Theme.Colors.accent : Color.clear)
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .stroke(understood ? Theme.Colors.accent : Theme.Colors.border, lineWidth: 1.5)
                            if understood {
                                Image(icon: Icon.check)
                                    .resizable().scaledToFit()
                                    .frame(width: 14, height: 14)
                                    .foregroundStyle(Theme.Colors.accentText)
                            }
                        }
                        .frame(width: 24, height: 24)

                        Text("I understand that anyone who sees these words can take my funds, permanently.",
                             bundle: .module, comment: "backup intro acknowledgement checkbox")
                            .textStyle(.sm)
                            .foregroundStyle(Theme.Colors.text1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)

                WalletButton(title: vm.step == .authenticating ? "Unlocking…" : "Continue") {
                    Task { await vm.begin() }
                }
                .disabled(!understood || vm.step == .authenticating)
                .opacity(!understood || vm.step == .authenticating ? 0.5 : 1)
            }
            .padding(Theme.Space.gutter)
        }
    }

    /// A red-iconed warning point (icon chip + text), matching the intro's three callouts.
    private func infoBullet(_ icon: Icon, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.x3) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.Colors.negative)
                Image(icon: icon)
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            text
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Folded-by-default list of how phrases actually get stolen.
    private var commonScams: some View {
        DisclosureGroup(isExpanded: $scamsExpanded) {
            VStack(alignment: .leading, spacing: Theme.Space.x3) {
                scamBullet(Text("Tricking you into copying your recovery phrase to the clipboard, where malware can read it.",
                                bundle: .module, comment: "common scam: clipboard"))
                scamBullet(Text("Tricking you into screenshotting it — then finding that image later in your synced cloud photos.",
                                bundle: .module, comment: "common scam: screenshot"))
                scamBullet(Text("Tricking you into typing it into a website or app that looks legitimate.",
                                bundle: .module, comment: "common scam: phishing site"))
            }
            .padding(.top, Theme.Space.x3)
        } label: {
            Text("Common scams", bundle: .module, comment: "backup intro: expandable scams section")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text0)
        }
        .tint(Theme.Colors.text2)   // disclosure chevron
    }

    private func scamBullet(_ text: Text) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.x2) {
            Text(verbatim: "•")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.negative)
            text
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Reveal (private key / WIF)

    /// A `.wif` wallet reveals a single private key for reference (no verify quiz — it's one opaque
    /// string, and the wallet is already backed up). Mono, wrapping, with copy.
    private var privateKeyReveal: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            Text("This is the private key for this wallet. Keep it secret and safe — anyone who has it controls the coins.",
                 bundle: .module, comment: "backup: private key reveal instruction")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)

            Text(verbatim: vm.privateKey)
                .font(.jbMono(15, .medium))
                .foregroundStyle(Theme.Colors.text0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.x3)
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

            Button { Clipboard.copy(vm.privateKey) } label: {
                Text("Copy private key", bundle: .module, comment: "backup: copy private key button")
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            WalletButton(title: "I've saved it") {
                vm.acknowledgePrivateKey()
            }
        }
        .padding(Theme.Space.gutter)
    }

    // MARK: - Reveal (word chips)

    private var mnemonicReveal: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x4) {
            if vm.verifyMissed {
                Text("That wasn't quite right — check your copy against the words below.",
                     bundle: .module, comment: "backup verify retry hint")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.negative)
            }
            Text("Write these \(vm.words.count) words down, in order.",
                 bundle: .module, comment: "backup reveal instruction; %lld is the word count")
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
            Text(verbatim: "\(index + 1)")   // word position number, not translatable copy
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
                Text("Check \(vm.questionIndex + 1) of \(vm.questions.count)",
                     bundle: .module, comment: "backup verify progress; e.g. Check 1 of 3")
                    .textStyle(.overline)
                    .foregroundStyle(Theme.Colors.text2)
                Text("Which was word #\(question.wordIndex + 1)?",
                     bundle: .module, comment: "backup verify question; %lld is the word position")
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
            Text("Backed up", bundle: .module, comment: "backup done heading")
                .textStyle(.h2)
                .foregroundStyle(Theme.Colors.text0)
            (vm.isPrivateKey
                ? Text("Keep that key safe — it's the only way to restore this wallet.",
                       bundle: .module, comment: "backup done note (private key)")
                : Text("Keep those words safe — they're the only way to restore this wallet.",
                       bundle: .module, comment: "backup done note"))
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
