// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The "this phone doesn't have your recovery phrase" sheet: explains why, takes the phrase (or the
/// private key of a single-key wallet), and puts it back under the SAME wallet
/// (`docs/key-storage.md §9`). No nav bar — swipe down to dismiss, like the other simple sheets.
///
/// It takes a live secret as input; screenshots are not blocked (the user's call), the app-switcher
/// snapshot is obscured.
struct RestoreKeyScreen: View {
    @Environment(\.dismiss) var dismiss
    @State var vm: RestoreKeyViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)

    init(viewModel: RestoreKeyViewModel) { _vm = State(initialValue: viewModel) }

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.x4) {
                    if vm.isDone { done } else { entry }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.gutter)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .obscuredWhenBackgrounded()
    }

    // MARK: - Entry

    @ViewBuilder
    private var entry: some View {
        (vm.isPrivateKey
            ? Text("Restore your private key", bundle: .module, comment: "restore key sheet heading (private key wallet)")
            : Text("Restore your recovery phrase", bundle: .module, comment: "restore key sheet heading"))
            .textStyle(.h1)
            .foregroundStyle(Theme.Colors.text0)

        (vm.isPrivateKey
            ? Text("This phone has \(vm.walletLabel)'s balance and history, but not its private key. A private key never leaves the phone it was saved on, so it didn't come across when you moved to this one. Until you enter it here, this wallet can't send.",
                   bundle: .module, comment: "restore key explainer (private key wallet); %@ is the wallet name")
            : Text("This phone has \(vm.walletLabel)'s balance and history, but not its recovery phrase. A recovery phrase never leaves the phone it was saved on, so it didn't come across when you moved to this one. Until you enter it here, this wallet can't send.",
                   bundle: .module, comment: "restore key explainer; %@ is the wallet name"))
            .textStyle(.body)
            .foregroundStyle(Theme.Colors.text1)

        walletSummary

        if vm.isPrivateKey {
            TextField("Private key (WIF)", text: $vm.text)
                .textFieldStyle(.plain)
                .font(.jbMono(15, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .fieldBoxInset()
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
                .onChange(of: vm.text) { _, _ in vm.edited() }
        } else {
            TextEditor(text: $vm.text)
                .textFieldStyle(.plain)   // clears Compose's amber focused-border ring (Android)
                .font(.jbMono(16, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .autocorrectionDisabled()
                .noAutocapitalization()
                .plainEditorBackground()
                .frame(minHeight: 140)
                .padding(Theme.Space.x2)
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
                .onChange(of: vm.text) { _, _ in vm.edited() }

            Text("Enter this wallet's 12 or 24 words, separated by spaces. They never leave this device.",
                 bundle: .module, comment: "restore key input hint")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }

        if let error = vm.errorMessage {
            Text(error)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.negative)
        }

        WalletButton(title: "Restore") { vm.submit() }
            .disabled(!vm.canSubmit)
            .opacity(vm.canSubmit ? 1 : 0.4)
            .padding(.top, Theme.Space.x2)

        (vm.isPrivateKey
            ? Text("Don't have the key? If your old phone still works, open this wallet there and move the coins to a wallet you hold the phrase for. Without the key, coins in this wallet can't be spent.",
                   bundle: .module, comment: "restore key: what to do without the private key")
            : Text("Don't have the phrase? If your old phone still works, open this wallet there and write the phrase down from Settings → Recovery phrase. Without the phrase, coins in this wallet can't be spent.",
                   bundle: .module, comment: "restore key: what to do without the phrase"))
            .textStyle(.xs)
            .foregroundStyle(Theme.Colors.text2)
    }

    // MARK: - Which wallet, and what it expects

    /// Public facts about the wallet being restored, so the user can tell it's the right one and
    /// knows what to enter. Nothing here is chosen: the kind of secret and the address type are
    /// read from the wallet, and the entry is checked against them.
    private var walletSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            summaryRow(title: Text("Wallet", bundle: .module, comment: "restore key summary: wallet name label"),
                       value: Text(verbatim: vm.walletLabel))
            summaryRow(title: Text("Enter", bundle: .module, comment: "restore key summary: label for the kind of secret expected"),
                       value: expectedSecret)
            if let address = vm.receiveAddress {
                summaryRow(title: Text("Receive address", bundle: .module, comment: "restore key summary: the wallet's current receive address"),
                           value: Text(verbatim: address), mono: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.x3)
        .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
    }

    private var expectedSecret: Text {
        if vm.isPrivateKey {
            return Text("Private key (WIF)", bundle: .module, comment: "restore key summary: this wallet takes a private key")
        }
        if let type = vm.addressTypeName {
            return Text("Recovery phrase · \(type)", bundle: .module,
                        comment: "restore key summary: this wallet takes a recovery phrase; %@ is the address type, e.g. Taproot")
        }
        return Text("Recovery phrase", bundle: .module, comment: "restore key summary: this wallet takes a recovery phrase")
    }

    private func summaryRow(title: Text, value: Text, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            title
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
            value
                .font(mono ? .jbMono(13, .regular) : .jbMono(15, .medium))
                .foregroundStyle(Theme.Colors.text0)
        }
    }

    // MARK: - Done

    @ViewBuilder
    private var done: some View {
        Text("Wallet restored", bundle: .module, comment: "restore key success heading")
            .textStyle(.h1)
            .foregroundStyle(Theme.Colors.text0)
        Text("\(vm.walletLabel) can send again from this phone. Keep your recovery phrase somewhere safe: you'll need it again on your next phone.",
             bundle: .module, comment: "restore key success body; %@ is the wallet name")
            .textStyle(.body)
            .foregroundStyle(Theme.Colors.text1)
        WalletButton(title: "Done") { dismiss() }
            .padding(.top, Theme.Space.x2)
    }
}
