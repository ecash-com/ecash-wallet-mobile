// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// App settings. Native inset-grouped `List`; currently a working appearance toggle + version.
/// Per-wallet info, per-network backends, app-lock, and currency land in the Settings slice
/// (PLAN.md Slice 7).
struct SettingsScreen: View {
    @AppStorage("appearance") var appearance = ""
    @Environment(AppState.self) var app
    @State var showBackup = false   // not `private` — Fuse bridges @State (skip-fuse rule)

    var body: some View {
        List {
            Section("Security") {
                if let wallet = app.selectedWallet {
                    Button { showBackup = true } label: {
                        HStack {
                            Text("Back up recovery phrase")
                                .textStyle(.body)
                                .foregroundStyle(Theme.Colors.text0)
                            Spacer()
                            Text(wallet.isBackedUp ? "Backed up" : "Not backed up")
                                .textStyle(.xs)
                                .foregroundStyle(wallet.isBackedUp ? Theme.Colors.positive : Theme.Colors.warning)
                        }
                    }
                }
                Toggle("Require unlock", isOn: Binding(
                    get: { app.appLock.enabled },
                    set: { app.appLock.setEnabled($0) }))
                Text("Ask for Face ID, fingerprint, or your passcode when opening the app.")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section("About") {
                Text(versionString)
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
            }
            // Dev affordance — the iOS Keychain survives app deletion, so this is the reliable wipe
            // for repeated testing. Returns to the empty state. (Gate behind a debug flag later.)
            Section("Developer") {
                Button { app.wipeAllWallets() } label: {
                    Text("Reset all wallet data")
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.negative)
                }
                Text("Wipes every wallet from the Keychain + storage on this device.")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
            }
        }
        .groupedListStyle()
        .navigationTitle("Settings")
        .fullScreenFlow(isPresented: $showBackup) {
            if let vm = app.makeBackupViewModel() {
                BackupFlowView(viewModel: vm)
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "eCash.com Wallet \(version) (\(build))"
    }
}
