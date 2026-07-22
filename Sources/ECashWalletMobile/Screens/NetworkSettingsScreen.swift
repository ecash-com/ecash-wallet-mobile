// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Settings → Network: a registry-driven list of every network's custom backend endpoint. Each row
/// pushes a self-contained editor that applies with its own checkmark. The list is driven by
/// `WalletNetwork.allCases`, so a new network (eCash / forknet) shows up here automatically once it's
/// in the registry — no new screen. Bitcoin mainnet is a first-class bundled network (creatable from
/// the wallet flows). The SOCKS5/Tor proxy row is hidden for now (see the commented Privacy section
/// below + `docs/backends-and-endpoints.md`). See `docs/backends-and-endpoints.md`.
struct NetworkSettingsScreen: View {
    @Environment(AppState.self) var app

    /// Registry-driven — every bundled network, in declaration order. Future eCash cases appear here
    /// automatically once added to the enum + registry.
    private var networks: [WalletNetwork] { WalletNetwork.selectable }

    var body: some View {
        List {
            Section {
                ForEach(networks, id: \.self) { network in
                    NavigationLink {
                        NetworkEndpointEditor(network: network)
                    } label: {
                        networkRow(network)
                    }
                }
            } header: {
                Text("Endpoints", bundle: .module, comment: "network endpoints section header")
            } footer: {
                Text("Each network has its own server. The app ships a default per network; override it to point at your own Electrum or Esplora server.",
                     bundle: .module, comment: "endpoints section explainer")
            }

            // SOCKS5 / Tor proxy — HIDDEN for now (2026-06-15) to avoid confusing users with a
            // feature that can't "just work": there's no bundled Tor, it needs a user-run SOCKS5
            // (Orbot on Android; nothing reachable on iOS), and the actual Tor route + `.onion`
            // remote-DNS is unverified. The plumbing stays intact (WalletManager.setProxy →
            // WalletEngine clients carry the proxy) — re-enable by uncommenting once verified. See
            // `docs/backends-and-endpoints.md` and `ProxySettingsEditor`.
            /*
            Section {
                NavigationLink {
                    ProxySettingsEditor()
                } label: {
                    HStack {
                        Text("SOCKS5 / Tor proxy", bundle: .module, comment: "proxy settings row")
                            .textStyle(.body)
                            .foregroundStyle(Theme.Colors.text0)
                        Spacer()
                        proxyValueLabel
                    }
                }
            } header: {
                Text("Privacy", bundle: .module, comment: "privacy section header")
            } footer: {
                Text("Routes traffic for every network through a SOCKS5 proxy (e.g. Tor via Orbot) to hide your IP and reach .onion servers.",
                     bundle: .module, comment: "proxy section explainer")
            }
            */
        }
        .groupedListStyle()
        .navigationTitle(Text("Network", bundle: .module, comment: "network settings screen title"))
    }

    // Paired with the hidden proxy row above — restore alongside it.
    /*
    @ViewBuilder
    private var proxyValueLabel: some View {
        if let proxy = app.proxy {
            Text(verbatim: proxy)
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text1)
        } else {
            Text("Off", bundle: .module, comment: "proxy disabled")
                .textStyle(.body)
                .foregroundStyle(Theme.Colors.text1)
        }
    }
    */

    /// Network name + its active endpoint (mono), with a "Custom" tag when overridden from default.
    private func networkRow(_ network: WalletNetwork) -> some View {
        let params = NetworkRegistry.params(for: network)
        return VStack(alignment: .leading, spacing: Theme.Space.x1) {
            HStack {
                Text(verbatim: params.displayName)
                    .textStyle(.body)
                    .foregroundStyle(Theme.Colors.text0)
                Spacer()
                if app.hasBackendOverride(for: network) {
                    Text("Custom", bundle: .module, comment: "endpoint overridden from the bundled default")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            Text(verbatim: app.backendURL(for: network))
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
                .singleLine()
        }
    }
}
