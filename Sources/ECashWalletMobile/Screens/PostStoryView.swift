// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService   // NetworkRegistry — fee labels are network-derived

/// Compose + publish a CoinNews Story (§6, unsigned). Topic picker (fetched topics + Global),
/// headline, optional link, body, fee tier, and a live **estimated cost** so the user sees what
/// publishing will cost before broadcasting. Presented as a sheet from the News tab.
struct PostStoryView: View {
    @Environment(\.dismiss) var dismiss   // not `private` — Fuse bridges view properties
    @Environment(AppState.self) var app
    @State var vm: PostStoryViewModel
    @State var showCreateTopic = false

    init(viewModel: PostStoryViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.bg0.ignoresSafeArea()
                content
            }
            .navigationTitle(Text("Post a Story", bundle: .module, comment: "compose story title"))
            .inlineNavigationTitle()
            .sheet(isPresented: $showCreateTopic) {
                if let cvm = app.makeCreateTopicViewModel(onCreated: { topic in vm.topicHex = topic.topicHex }) {
                    CreateTopicView(viewModel: cvm)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if case .published = vm.step {
            publishedView
        } else {
            composeForm
        }
    }

    // MARK: - Compose

    /// Smallest-unit label for THIS network — "sat" on Bitcoin, "szat" on eCash.
    /// Never hardcode it: an eCash fee shown as "sat/vB" borrows Bitcoin's unit for
    /// another chain's money.
    private var subUnit: String { NetworkRegistry.params(for: vm.network).subUnitLabel }

    private var composeForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                NetworkBadge(network: vm.network)

                // A Picker (not a Menu+ForEach) so the dynamic topic list renders flush on Android —
                // SkipUI indents ForEach children inside a Menu; a Picker doesn't. "New topic" is a
                // separate action (a Picker can't hold one) beside the label.
                HStack {
                    fieldLabel("Topic")
                    Spacer()
                    Button { showCreateTopic = true } label: {
                        Text("New topic", bundle: .module, comment: "create a new topic")
                            .textStyle(.overline)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
                Picker("Topic", selection: $vm.topicHex) {
                    Text("Global", bundle: .module, comment: "global / no topic")
                        .tag(PostStoryViewModel.globalTopicHex)
                    ForEach(vm.availableTopics) { topic in
                        Text(verbatim: topic.name).tag(topic.topicHex)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.Colors.text0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .menuFieldBox()
                .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

                fieldLabel("Headline")
                TextField("", text: $vm.headline)
                    .textFieldStyle(.plain)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                    .fieldBoxInset()
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

                fieldLabel("Link (optional)")
                TextField("https://", text: $vm.url)
                    .textFieldStyle(.plain)
                    .textStyle(.mono)
                    .foregroundStyle(Theme.Colors.text0)
                    .autocorrectionDisabled()
                    .fieldBoxInset()
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

                fieldLabel("Body (optional)")
                TextEditor(text: $vm.body)
                    .textFieldStyle(.plain)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                    .plainEditorBackground()
                    .frame(minHeight: 100)
                    .padding(Theme.Space.x2)
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))

                fieldLabel("Fee")
                menuRow(title: feeTitle) {
                    // Explicit buttons, not ForEach: SkipUI gives ForEach children a Compose
                    // start-inset inside a Menu, so they render indented vs. flush direct buttons.
                    Button { vm.tier = .slow } label: { Text(verbatim: feeOptionLabel(.slow)) }
                    Button { vm.tier = .normal } label: { Text(verbatim: feeOptionLabel(.normal)) }
                    Button { vm.tier = .fast } label: { Text(verbatim: feeOptionLabel(.fast)) }
                    Button { vm.tier = .custom } label: { Text(verbatim: feeOptionLabel(.custom)) }
                }
                if vm.tier == .custom {
                    HStack(spacing: Theme.Space.x2) {
                        TextField("10", text: $vm.customFeeText)
                            .textFieldStyle(.plain)
                            .textStyle(.body)
                            .foregroundStyle(Theme.Colors.text0)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .fieldBoxInset()
                            .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        Text(verbatim: "\(subUnit)/vB")
                            .textStyle(.sm)
                            .foregroundStyle(Theme.Colors.text2)
                    }
                }

                costRow

                if case .failed(let message) = vm.step {
                    Text(verbatim: message)
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.negative)
                }

                WalletButton(title: isPublishing ? "Publishing…" : "Publish") {
                    Task { await vm.publishStory() }
                }
                .disabled(!vm.canPublish)
                .opacity(vm.canPublish ? 1 : 0.4)
                .padding(.top, Theme.Space.x2)
            }
            .padding(Theme.Space.gutter)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private var costRow: some View {
        HStack {
            Text("Estimated cost", bundle: .module, comment: "publish cost estimate label")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "≈ \(vm.estimatedCostText)")
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                if let fiat = vm.estimatedCostFiat {
                    Text(verbatim: "≈ \(fiat)")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                }
            }
        }
        .padding(Theme.Space.x3)
        .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Published

    private var publishedView: some View {
        VStack(spacing: Theme.Space.x4) {
            Text("Published", bundle: .module, comment: "story published heading")
                .textStyle(.h1)
                .foregroundStyle(Theme.Colors.text0)
            Text("Your story is broadcasting. It will appear in the feed once a node indexes it.",
                 bundle: .module, comment: "story published note")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)
                .multilineTextAlignment(.center)
            WalletButton(title: "Done") { dismiss() }
                .padding(.top, Theme.Space.x2)
        }
        .padding(Theme.Space.gutter)
    }

    // MARK: - Bits

    private var isPublishing: Bool { if case .publishing = vm.step { return true }; return false }
    private var feeTitle: String { "\(vm.tier.label) · \(vm.effectiveSatPerVByte) \(subUnit)/vB" }
    private func feeOptionLabel(_ tier: PostStoryViewModel.FeeTier) -> String {
        tier == .custom ? "Custom…" : "\(tier.label) · \(tier.satPerVByte) \(subUnit)/vB"
    }

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .textStyle(.overline)
            .foregroundStyle(Theme.Colors.text2)
    }

    @ViewBuilder
    private func menuRow<Content: View>(title: String, @ViewBuilder menu: () -> Content) -> some View {
        Menu {
            menu()
        } label: {
            HStack {
                Text(verbatim: title)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                Spacer()
                Image(icon: Icon.expand)
                    .resizable().scaledToFit().frame(width: 18, height: 18)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .menuFieldBox()
            .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }
}
