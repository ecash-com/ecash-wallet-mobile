// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Route for pushing one sidechain's detail screen.
struct SidechainDetailRoute: Hashable {
    let slot: Int
}

/// The sidechains on the selected wallet's network: the active ones with what each holds in escrow,
/// and the ones being voted in. Read-only. Presented as a sheet from Home; tapping a sidechain pushes
/// its detail. Design: `docs/sidechains-ui.md` §3a.
///
/// Live while visible: polls `refresh()` every 30 s, which costs one chain-tip request unless a new
/// block has arrived.
struct SidechainsScreen: View {
    @Environment(\.dismiss) var dismiss   // not `private` — Fuse bridges view properties
    @Environment(AppState.self) var app
    @State var vm: SidechainsViewModel

    init(viewModel: SidechainsViewModel) {
        _vm = State(initialValue: viewModel)
    }

    static let pollNanoseconds: UInt64 = 30_000_000_000

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Sidechains", bundle: .module, comment: "sidechains screen title"))
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        CloseToolbarButton { dismiss() }
                    }
                }
                // Every push in this stack is VALUE-based, with its destination registered here at the
                // root. Mixing a closure-style `NavigationLink { … }` (list → detail) with a value push
                // (detail → deposit) made iOS stack a second detail screen on top of the deposit one.
                .navigationDestination(for: SidechainDetailRoute.self) { route in
                    SidechainDetailScreen(viewModel: vm, slot: route.slot)
                }
                .navigationDestination(for: SidechainDepositRoute.self) { route in
                    if let entry = vm.entry(slot: route.slot),
                       let depositVM = app.makeSidechainDepositViewModel(sidechain: entry.sidechain) {
                        SidechainDepositScreen(viewModel: depositVM)
                    }
                }
        }
        .task {
            while !Task.isCancelled {
                await vm.refresh()
                try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            }
        }
    }

    // Native inset-grouped `List` (never VStack+ForEach for dynamic rows: that recurses in SkipUI's
    // Compose layout, see ActivityScreen).
    @ViewBuilder private var content: some View {
        if vm.isFirstLoad {
            VStack(spacing: Theme.Space.x3) {
                ProgressView()
                Text("Loading sidechains…", bundle: .module, comment: "sidechains first load")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.bg0)
        } else if !vm.hasData {
            firstLoadFailed
        } else {
            List {
                Section(header: activeHeader, footer: staleFooter) {
                    if vm.entries.isEmpty {
                        Text("No sidechains are active on this network yet.",
                             bundle: .module, comment: "sidechains empty state")
                            .textStyle(.sm)
                            .foregroundStyle(Theme.Colors.text2)
                    } else {
                        ForEach(vm.entries) { entry in
                            NavigationLink(value: SidechainDetailRoute(slot: entry.sidechain.slot)) {
                                SidechainRow(entry: entry, unitLabel: vm.unitLabel)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.Colors.bg2)

                if !vm.proposals.isEmpty {
                    Section(header: sectionHeader(Text("Being voted in", bundle: .module,
                                                       comment: "sidechains section: proposals")),
                            footer: proposalsFooter) {
                        ForEach(vm.proposals) { proposal in
                            ProposalRow(proposal: proposal, progress: vm.activationProgress(for: proposal))
                        }
                    }
                    .listRowBackground(Theme.Colors.bg2)
                }
            }
            .groupedListStyle()
            .themedGroupedListBackground()
            .refreshable { await vm.forceRefresh() }
        }
    }

    private var activeHeader: some View {
        HStack {
            sectionHeader(Text("Active", bundle: .module, comment: "sidechains section: active"))
            Spacer()
            NetworkBadge(network: vm.network)
        }
    }

    @ViewBuilder private var staleFooter: some View {
        if vm.isStale {
            Text("Couldn't reach the network. Showing the last update. Pull to retry.",
                 bundle: .module, comment: "sidechains stale data footer")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.warning)
        } else if let tip = vm.tip {
            Text("Up to date as of block \(String(tip.height))",
                 bundle: .module, comment: "sidechains freshness footer; %@ is a block height")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    private var proposalsFooter: some View {
        Text("Miners vote a sidechain into a slot over many blocks. It can take deposits once it activates.",
             bundle: .module, comment: "sidechains proposals explainer")
            .textStyle(.xs)
            .foregroundStyle(Theme.Colors.text2)
    }

    private var firstLoadFailed: some View {
        VStack(spacing: Theme.Space.x4) {
            Text("Couldn't load sidechains", bundle: .module, comment: "sidechains load error title")
                .textStyle(.h3)
                .foregroundStyle(Theme.Colors.text0)
            Text("The sidechain service for this network didn't answer. Check your connection and try again.",
                 bundle: .module, comment: "sidechains load error body")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
                .multilineTextAlignment(.center)
            Button {
                Task { await vm.forceRefresh() }
            } label: {
                Text("Try again", bundle: .module, comment: "retry button")
                    .textStyle(.button)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Colors.accent)
        }
        .padding(Theme.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.bg0)
    }

    private func sectionHeader(_ text: Text) -> some View {
        text.textStyle(.overline).foregroundStyle(Theme.Colors.text1)
    }
}
