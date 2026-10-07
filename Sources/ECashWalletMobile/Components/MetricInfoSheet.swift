// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A metric's methodology: what it is, where it comes from, what it can't tell you. No nav bar —
/// swipe to dismiss, like tx detail (a toolbar renders a grey Material bar on Android).
struct MetricInfoSheet: View {
    let metric: DashboardMetric
    let network: DashboardNetwork

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.x4) {
                    Text(metric.title, bundle: .module)
                        .textStyle(.h2)
                        .foregroundStyle(Theme.Colors.text0)
                    Text(metric.definition, bundle: .module)
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text1)
                    block("SOURCE", "\(network.explorerURL)\(metric.source.replacingOccurrences(of: "GET ", with: ""))")
                    block("REFRESHED", "Every 5 minutes while the dashboard is open")
                    VStack(alignment: .leading, spacing: Theme.Space.x1) {
                        Text("LIMITATIONS", bundle: .module, comment: "metric info: limitations header")
                            .textStyle(.overline)
                            .foregroundStyle(Theme.Colors.text2)
                        Text(metric.limitation, bundle: .module)
                            .textStyle(.sm)
                            .foregroundStyle(Theme.Colors.text1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.gutter)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func block(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            Text(title, bundle: .module)
                .textStyle(.overline)
                .foregroundStyle(Theme.Colors.text2)
            Text(verbatim: value)
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text1)
        }
    }
}
