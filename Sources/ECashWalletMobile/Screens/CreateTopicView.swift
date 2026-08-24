// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService   // NetworkRegistry — fee labels are network-derived

/// Create a new CoinNews topic (§5). The user supplies a name + retention; the 4-byte topic ID is
/// prefilled with a random default (so picking it isn't required) but stays editable for power users.
/// Broadcast as an `OP_RETURN`, bio-gated like posting a Story.
struct CreateTopicView: View {
    @Environment(\.dismiss) var dismiss
    @State var vm: CreateTopicViewModel

    init(viewModel: CreateTopicViewModel) {
        _vm = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.bg0.ignoresSafeArea()
                content
            }
            .navigationTitle(Text("New topic", bundle: .module, comment: "create topic title"))
            .inlineNavigationTitle()
        }
    }

    @ViewBuilder private var content: some View {
        if case .published = vm.step {
            VStack(spacing: Theme.Space.x4) {
                Text("Topic created", bundle: .module, comment: "topic created heading")
                    .textStyle(.h1).foregroundStyle(Theme.Colors.text0)
                Text("Broadcasting. It'll appear once a node indexes it.",
                     bundle: .module, comment: "topic created note")
                    .textStyle(.body).foregroundStyle(Theme.Colors.text1).multilineTextAlignment(.center)
                WalletButton(title: "Done") { dismiss() }.padding(.top, Theme.Space.x2)
            }
            .padding(Theme.Space.gutter)
        } else {
            form
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x4) {
                NetworkBadge(network: vm.network)

                fieldLabel("Name")
                TextField("", text: $vm.name)
                    .textFieldStyle(.plain)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                    .fieldBoxInset()
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

                fieldLabel("Topic ID (4-byte hex)")
                TextField("a1a1a1a1", text: $vm.topicHex)
                    .textFieldStyle(.plain)
                    .textStyle(.mono)
                    .foregroundStyle(Theme.Colors.text0)
                    .autocorrectionDisabled()
                    .fieldBoxInset()
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                if vm.topicValid {
                    Text("Auto-generated — edit only to target a specific topic.",
                         bundle: .module, comment: "topic id prefilled hint")
                        .textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                } else {
                    Text("Enter exactly 8 hex characters (4 bytes).",
                         bundle: .module, comment: "topic id validation")
                        .textStyle(.xs).foregroundStyle(Theme.Colors.negative)
                }

                fieldLabel("Retention (days, 0 = forever)")
                TextField("0", text: $vm.retentionText)
                    .textFieldStyle(.plain)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .fieldBoxInset()
                    .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))

                fieldLabel("Fee")
                menuRow(title: feeTitle) {
                    // Explicit buttons, not ForEach (ForEach children get a Compose start-inset in a
                    // SkipUI Menu — they render indented vs. flush direct buttons).
                    Button { vm.tier = .slow } label: { Text(verbatim: feeOptionLabel(.slow)) }
                    Button { vm.tier = .normal } label: { Text(verbatim: feeOptionLabel(.normal)) }
                    Button { vm.tier = .fast } label: { Text(verbatim: feeOptionLabel(.fast)) }
                    Button { vm.tier = .custom } label: { Text(verbatim: feeOptionLabel(.custom)) }
                }
                if vm.tier == .custom {
                    HStack(spacing: Theme.Space.x2) {
                        TextField("10", text: $vm.customFeeText)
                            .textFieldStyle(.plain).textStyle(.body).foregroundStyle(Theme.Colors.text0)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .fieldBoxInset()
                            .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        Text(verbatim: "\(subUnit)/vB").textStyle(.sm).foregroundStyle(Theme.Colors.text2)
                    }
                }

                costRow

                if case .failed(let message) = vm.step {
                    Text(verbatim: message).textStyle(.sm).foregroundStyle(Theme.Colors.negative)
                }

                WalletButton(title: isPublishing ? "Creating…" : "Create topic") {
                    Task { await vm.create() }
                }
                .disabled(!vm.canCreate)
                .opacity(vm.canCreate ? 1 : 0.4)
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
            Text("Estimated cost", bundle: .module, comment: "create topic cost label")
                .textStyle(.sm).foregroundStyle(Theme.Colors.text1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "≈ \(vm.estimatedCostText)").textStyle(.body).foregroundStyle(Theme.Colors.text0)
                if let fiat = vm.estimatedCostFiat {
                    Text(verbatim: "≈ \(fiat)").textStyle(.xs).foregroundStyle(Theme.Colors.text2)
                }
            }
        }
        .padding(Theme.Space.x3)
        .background(Theme.Colors.bg1, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var isPublishing: Bool { if case .publishing = vm.step { return true }; return false }
    private var feeTitle: String { "\(vm.tier.label) · \(vm.effectiveSatPerVByte) \(subUnit)/vB" }
    private func feeOptionLabel(_ tier: PostStoryViewModel.FeeTier) -> String {
        tier == .custom ? "Custom…" : "\(tier.label) · \(tier.satPerVByte) \(subUnit)/vB"
    }

    /// Smallest-unit label for THIS wallet's network — "sat" on Bitcoin, "szat" on eCash.
    /// Never hardcode it: an eCash fee shown as "sat/vB" borrows Bitcoin's unit for another
    /// chain's money.
    private var subUnit: String { NetworkRegistry.params(for: vm.network).subUnitLabel }

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module).textStyle(.overline).foregroundStyle(Theme.Colors.text2)
    }

    @ViewBuilder
    private func menuRow<Content: View>(title: String, @ViewBuilder menu: () -> Content) -> some View {
        Menu {
            menu()
        } label: {
            HStack {
                Text(verbatim: title).textStyle(.body).foregroundStyle(Theme.Colors.text0)
                Spacer()
                Image(icon: Icon.expand).resizable().scaledToFit().frame(width: 18, height: 18)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .menuFieldBox()
            .background(Theme.Colors.bg2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }
}
