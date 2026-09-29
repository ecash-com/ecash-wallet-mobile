// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// One sidechain: what it is, what it holds, and the withdrawals miners are voting on right now.
/// Read-only. Pushed from `SidechainsScreen`. Design: `docs/sidechains-ui.md` §3b.
///
/// The withdrawal section is the honest answer to "how long to get coins back": real batches with
/// real vote counts, and the minimum wait from the chain's own BIP300 constants. Deposits join this
/// screen once the deposit engine exists (`docs/sidechain-deposits.md` §7).
struct SidechainDetailScreen: View {
    @State var vm: SidechainsViewModel
    let slot: Int

    init(viewModel: SidechainsViewModel, slot: Int) {
        _vm = State(initialValue: viewModel)
        self.slot = slot
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: vm.entry(slot: slot)?.sidechain.title ?? ""))
            .inlineNavigationTitle()
            .task { await vm.loadBundles(slot: slot) }
    }

    @ViewBuilder private var content: some View {
        if let entry = vm.entry(slot: slot) {
            List {
                Section {
                    if !entry.sidechain.description.isEmpty {
                        Text(verbatim: entry.sidechain.description)
                            .textStyle(.body)
                            .foregroundStyle(Theme.Colors.text0)
                    }
                    factRow(Text("Network", bundle: .module, comment: "sidechain detail: parent network")) {
                        NetworkBadge(network: vm.network)
                    }
                    factRow(Text("Slot", bundle: .module, comment: "sidechain detail: BIP300 slot")) {
                        Text(verbatim: String(entry.sidechain.slot))
                    }
                    factRow(Text("Active since", bundle: .module, comment: "sidechain detail: activation")) {
                        Text("Block \(String(entry.sidechain.activationHeight))", bundle: .module,
                             comment: "a block height; %@ is the height")
                    }
                    factRow(Text("In escrow", bundle: .module, comment: "sidechain detail: treasury value")) {
                        if let treasury = entry.treasury {
                            Text(verbatim: "\(Amount(sats: treasury.valueSats).formattedCoin()) \(vm.unitLabel)")
                        } else {
                            Text("No deposits yet", bundle: .module, comment: "sidechain with an empty escrow")
                        }
                    }
                }
                .listRowBackground(Theme.Colors.bg2)

                Section {
                    // Deposits only ever run on a FRESH treasury read (the deposit flow re-reads it),
                    // but don't offer one while this screen's own data is known to be stale.
                    NavigationLink(value: SidechainDepositRoute(slot: slot)) {
                        HStack(spacing: Theme.Space.x3) {
                            Image(icon: Icon.send)
                                .resizable().scaledToFit()
                                .frame(width: 16, height: 16)
                                .foregroundStyle(Theme.Colors.accent)
                            Text("Deposit to \(entry.sidechain.title)", bundle: .module,
                                 comment: "sidechain detail: start a deposit; %@ is the sidechain name")
                                .textStyle(.body)
                                .foregroundStyle(Theme.Colors.text0)
                        }
                    }
                    .disabled(vm.isStale)
                }
                .listRowBackground(Theme.Colors.bg2)

                Section(header: sectionHeader(Text("Withdrawals in progress", bundle: .module,
                                                   comment: "sidechain detail section: withdrawal batches")),
                        footer: withdrawalFooter) {
                    withdrawalRows
                }
                .listRowBackground(Theme.Colors.bg2)
            }
            .groupedListStyle()
            .themedGroupedListBackground()
            .refreshable {
                await vm.forceRefresh()
                await vm.loadBundles(slot: slot)
            }
        } else {
            // The slot vanished on a refresh (deactivated). Rare, but don't show a blank screen.
            Text("This sidechain is no longer active on this network.",
                 bundle: .module, comment: "sidechain detail: slot no longer active")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text2)
                .padding(Theme.Space.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.bg0)
        }
    }

    @ViewBuilder private var withdrawalRows: some View {
        if let bundles = vm.bundlesBySlot[slot] {
            if bundles.isEmpty {
                Text("None right now.", bundle: .module, comment: "no withdrawal batches pending")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text2)
            } else {
                ForEach(bundles) { bundle in
                    WithdrawalBatchRow(bundle: bundle, progress: vm.withdrawalProgress(for: bundle))
                }
            }
        } else if vm.bundleFailures.contains(slot) {
            Text("Couldn't load withdrawals. Pull to retry.", bundle: .module,
                 comment: "withdrawal batches failed to load")
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.warning)
        } else {
            ProgressView()
        }
    }

    /// The minimum wait, from the chain's own vote threshold: a batch needs that many upvotes, at
    /// most one per block, before it pays out.
    @ViewBuilder private var withdrawalFooter: some View {
        if let blocks = vm.minimumWithdrawalBlocks {
            // Two lines rather than one sentence: a row of Texts in an HStack doesn't wrap, and the
            // duration is its own view (it picks singular/plural wording).
            VStack(alignment: .leading, spacing: 2) {
                Text("Minimum wait to move coins back to the mainchain:", bundle: .module,
                     comment: "withdrawal wait explainer; a duration like 'about 3 months' follows on the next line")
                ApproximateDurationText(duration: ApproximateDuration(blocks: blocks))
            }
            .textStyle(.xs)
            .foregroundStyle(Theme.Colors.text2)
        }
    }

    private func factRow<Value: View>(_ label: Text, @ViewBuilder value: () -> Value) -> some View {
        HStack {
            label
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
            Spacer()
            value()
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text0)
        }
    }

    private func sectionHeader(_ text: Text) -> some View {
        text.textStyle(.overline).foregroundStyle(Theme.Colors.text1)
    }
}
