// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Per-network backend editor (pushed from `NetworkSettingsScreen`): a custom **Electrum or Esplora**
/// endpoint for one specific `network`, independent of which wallet is selected. "Test connection"
/// validates (through the app-wide proxy, if set) before the user applies with the top-right
/// checkmark. Applying re-syncs only when this is the selected wallet's current network.
/// The SOCKS5/Tor proxy is global and lives in `ProxySettingsEditor`. See `docs/backends-and-endpoints.md`.
struct NetworkEndpointEditor: View {
    let network: WalletNetwork

    @Environment(AppState.self) var app
    @Environment(\.dismiss) var dismiss
    // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var kind = "electrum"
    @State var url = ""
    @State var testing = false
    @State var testResult: Bool? = nil   // nil = untested
    @State var loaded = false

    var body: some View {
        let params = NetworkRegistry.params(for: network)
        List {
            Section {
                Picker("Server type", selection: $kind) {
                    Text("Electrum", bundle: .module, comment: "backend type").tag("electrum")
                    Text("Esplora", bundle: .module, comment: "backend type").tag("esplora")
                }
                .onChange(of: kind) { _, _ in testResult = nil }

                TextField("Server URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(.jbMono(14, .regular))
                    .foregroundStyle(Theme.Colors.text0)
                    .autocorrectionDisabled()
                    .noAutocapitalization()
                    .onChange(of: url) { _, _ in testResult = nil }

                if let problem = validationMessage {
                    Text(verbatim: problem)
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.negative)
                }

                testRow
            } header: {
                Text("Endpoint", bundle: .module, comment: "endpoint section header")
            } footer: {
                Text("Electrum: ssl:// or tcp://. Esplora: https://. Default: \(app.defaultBackendURL(for: network))",
                     bundle: .module, comment: "endpoint hint; %@ is the default URL")
            }

            Section {
                Button { reset() } label: {
                    Text("Reset to bundled default", bundle: .module, comment: "restore the app's built-in endpoint")
                        .textStyle(.body)
                        .foregroundStyle(isDefault ? Theme.Colors.text2 : Theme.Colors.accent)
                }
                .disabled(isDefault)
            } footer: {
                Text("Fills the form with the app's built-in endpoint (\(app.defaultBackendURL(for: network))). Tap the checkmark to apply.",
                     bundle: .module, comment: "reset row explainer; %@ is the default URL")
            }
        }
        .groupedListStyle()
        .navigationTitle(Text(verbatim: params.displayName))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ConfirmToolbarButton { save(); dismiss() }
                    .disabled(validationMessage != nil)
            }
        }
        .task {
            guard !loaded else { return }
            kind = app.backendKind(for: network)
            url = app.backendURL(for: network)
            loaded = true
        }
    }

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the current entry can't be saved, or nil when it's acceptable. Syntax only — whether the
    /// server answers, and on the right chain, is what Test connection is for. Empty is allowed: it
    /// means "clear my override", not "invalid".
    private var validationMessage: String? {
        BackendURLValidator.validationMessage(kind: kind, url: trimmedURL)
    }

    /// True when the form already matches what this network resolves to with no override.
    ///
    /// Compares against the EFFECTIVE default, not the bundled one: since remote config landed,
    /// clearing an override lands you on the remote default, so the bundled value is just another
    /// URL a user might legitimately want to pin.
    private var isDefault: Bool {
        kind == app.effectiveDefaultBackendKind(for: network)
            && trimmedURL == app.effectiveDefaultBackendURL(for: network)
    }

    private var testRow: some View {
        Button { Task { await runTest() } } label: {
            HStack(spacing: Theme.Space.x2) {
                if testing {
                    ProgressView()
                } else if let ok = testResult {
                    Image(icon: ok ? Icon.check : Icon.caution)
                        .resizable().scaledToFit().frame(width: 14, height: 14)
                        .foregroundStyle(ok ? Theme.Colors.positive : Theme.Colors.negative)
                }
                (testResult == nil
                    ? Text("Test connection", bundle: .module, comment: "validate endpoint")
                    : (testResult == true
                        ? Text("Connected", bundle: .module, comment: "endpoint reachable")
                        : Text("Couldn't connect", bundle: .module, comment: "endpoint unreachable")))
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
            }
        }
        .buttonStyle(.plain)
        .disabled(trimmedURL.isEmpty || testing)
    }

    private func runTest() async {
        testing = true
        testResult = nil
        // Probe through the app-wide proxy if one is configured, mirroring how a real sync connects.
        let ok = await app.testBackend(kind: kind, url: trimmedURL, socks5: app.proxy)
        testResult = ok
        testing = false
    }

    private func save() {
        // Clear the override only when the form matches what no-override already resolves to.
        // Comparing against the BUNDLED default instead is the bug that made Bitcoin unsettable:
        // its bundled default is Blockstream, so entering that URL deleted the override and let the
        // remote Esplora default take over — indistinguishable from "it didn't save".
        if trimmedURL.isEmpty || isDefault {
            app.resetBackend(for: network)
        } else {
            app.setBackend(network: network, kind: kind, url: trimmedURL)
        }
        // Only the selected wallet syncs; re-sync just when its current network is the one we changed.
        if network == app.selectedWallet?.network {
            Task { await app.sync(force: true) }
        }
    }

    /// Repopulate the form with the bundled default. Doesn't persist — the user applies with the
    /// checkmark (which, since the URL now equals the default, clears any override via `save`).
    private func reset() {
        // Populate with the EFFECTIVE default so applying afterwards clears the override rather
        // than pinning the bundled URL as a new one.
        kind = app.effectiveDefaultBackendKind(for: network)
        url = app.effectiveDefaultBackendURL(for: network)
        testResult = nil
    }
}
