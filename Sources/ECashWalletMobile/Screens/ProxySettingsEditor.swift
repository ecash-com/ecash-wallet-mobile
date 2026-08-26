// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The app-wide SOCKS5/Tor proxy editor (pushed from `NetworkSettingsScreen` → Privacy). Unlike the
/// per-network endpoints, the proxy is a single global setting applied to every network's client.
/// Applied with the top-right checkmark; applying re-syncs the selected wallet so the change takes
/// effect immediately. There's no bundled Tor in v1 — the user runs their own SOCKS5 provider (Orbot,
/// local Tor, an SSH tunnel). Embedded Tor is v2. See `docs/backends-and-endpoints.md`.
struct ProxySettingsEditor: View {
    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss
    // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var enabled = false
    @State var text = ""
    @State var loaded = false

    var body: some View {
        List {
            Section {
                Toggle("Route through SOCKS5 proxy", isOn: $enabled)
                if enabled {
                    TextField("127.0.0.1:9050", text: $text)
                        .textFieldStyle(.plain)
                        .font(.jbMono(14, .regular))
                        .foregroundStyle(Theme.Colors.text0)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                }
            } footer: {
                Text("Run Tor (e.g. Orbot at 127.0.0.1:9050) to hide your IP and reach .onion servers. Applies to every network.",
                     bundle: .module, comment: "proxy explainer")
            }
        }
        .groupedListStyle()
        .navigationTitle(Text("Proxy", bundle: .module, comment: "proxy editor screen title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ConfirmToolbarButton { save(); dismiss() }
            }
        }
        .task {
            guard !loaded else { return }
            if let proxy = app.proxy { enabled = true; text = proxy }
            loaded = true
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        app.setProxy(enabled && !trimmed.isEmpty ? trimmed : nil)
        Task { await app.sync(force: true) }   // proxy is global; re-sync the selected wallet to pick it up
    }
}
