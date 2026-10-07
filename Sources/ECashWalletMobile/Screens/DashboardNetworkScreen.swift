// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The network section in full: every metric with its definition inline, the activity chart, and the
/// latest blocks (tap → the block in the explorer, in the system browser).
struct DashboardNetworkScreen: View {
    @Environment(AppState.self) var app

    var body: some View {
        let model = app.dashboard
        let snapshot = model.chain.value
        let now = Int64(Date().timeIntervalSince1970)
        List {
            Section(header: header(Text("Metrics", bundle: .module, comment: "network screen: metrics section")),
                    footer: DashboardFreshness(updatedAt: model.chain.updatedAt, stale: model.chain.lastAttemptFailed)) {
                metricRow(.blockHeight, snapshot.map { DashboardFormat.integer($0.tipHeight) })
                metricRow(.transactions24h, snapshot.map { DashboardFormat.integer($0.transactions24h) })
                metricRow(.observedTPS, snapshot.map { DashboardFormat.tps($0.observedTPS) })
                metricRow(.mempool, snapshot.map { "\(DashboardFormat.integer($0.mempoolCount)) tx · \(DashboardFormat.compact(Double($0.mempoolVSize))) vB" })
            }
            .listRowBackground(Theme.Colors.bg2)

            if let snapshot, !snapshot.blocks.isEmpty {
                Section(header: header(Text("Activity by block", bundle: .module, comment: "network screen: chart section"))) {
                    BlockActivityBars(blocks: snapshot.blocks, height: 96)
                        .padding(.vertical, Theme.Space.x2)
                }
                .listRowBackground(Theme.Colors.bg2)

                Section(header: header(Text("Latest blocks", bundle: .module, comment: "network screen: blocks section")),
                        footer: Text("Miner labels come from the explorer and may be incomplete.", bundle: .module,
                                     comment: "network screen: miner label caveat")
                            .textStyle(.xs).foregroundStyle(Theme.Colors.text2)) {
                    ForEach(Array(snapshot.blocks.prefix(10))) { block in
                        blockRow(block, now: now)
                    }
                }
                .listRowBackground(Theme.Colors.bg2)
            }
        }
        .groupedListStyle()
        .themedGroupedListBackground()
        .refreshable { await app.dashboard.refresh(force: true) }
        // Pushing this screen cancels the Dashboard root's refresh loop, so catch up here.
        .task { await app.dashboard.refresh() }
        .navigationTitle(Text("\(model.network.displayName) network", bundle: .module,
                              comment: "network screen title; %@ is the network name"))
        .inlineNavigationTitle()
    }

    private func header(_ text: Text) -> some View {
        text.textStyle(.overline).foregroundStyle(Theme.Colors.text2)
    }

    private func metricRow(_ metric: DashboardMetric, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title, bundle: .module)
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
                Spacer(minLength: Theme.Space.x2)
                Text(verbatim: value ?? "—")
                    .font(.jbMono(15, .medium))
                    .foregroundStyle(Theme.Colors.text0)
            }
            Text(metric.definition, bundle: .module)
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
        .padding(.vertical, Theme.Space.x1)
    }

    @ViewBuilder private func blockRow(_ block: DashboardBlock, now: Int64) -> some View {
        if let url = URL(string: "\(app.dashboard.network.explorerURL)/block/\(block.hash)") {
            Link(destination: url) { DashboardBlockRow(block: block, now: now) }
                .buttonStyle(.plain)
        } else {
            DashboardBlockRow(block: block, now: now)
        }
    }
}
