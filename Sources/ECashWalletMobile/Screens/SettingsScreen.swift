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
    @State var showSplit = false

    var body: some View {
        List {
            Section(header: sectionHeader(Text("Security", bundle: .module, comment: "settings section: security"))) {
                if let wallet = app.selectedWallet {
                    Button { showBackup = true } label: {
                        HStack {
                            Text("Back up recovery phrase", bundle: .module, comment: "settings security row")
                                .textStyle(.body)
                                .foregroundStyle(Theme.Colors.text0)
                            Spacer()
                            (wallet.isBackedUp
                                ? Text("Backed up", bundle: .module, comment: "wallet backup status")
                                : Text("Not backed up", bundle: .module, comment: "wallet backup status"))
                                .textStyle(.xs)
                                .foregroundStyle(wallet.isBackedUp ? Theme.Colors.positive : Theme.Colors.warning)
                        }
                    }

                    // Split coins — eCash only, and only when the wallet actually holds pre-fork coins
                    // (shared with Bitcoin). No row when there's nothing to split.
                    if wallet.network == .ecash, let summary = app.splitSummary, summary.needsSplitCount > 0 {
                        Button { showSplit = true } label: {
                            HStack {
                                Text("Split coins", bundle: .module, comment: "settings: split coins row")
                                    .textStyle(.body)
                                    .foregroundStyle(Theme.Colors.text0)
                                Spacer()
                                Text(verbatim: summary.needsSplitCount == 1
                                        ? "1 coin to split"
                                        : "\(summary.needsSplitCount) coins to split")
                                    .textStyle(.xs)
                                    .foregroundStyle(Theme.Colors.text2)
                            }
                        }
                    }
                }
                Toggle(isOn: Binding(
                    get: { app.appLock.enabled },
                    set: { app.appLock.setEnabled($0) })) {
                    Text("Require unlock", bundle: .module, comment: "app-lock toggle label")
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text0)
                }
                Text("Ask for Face ID, fingerprint, or your passcode when opening the app.",
                     bundle: .module, comment: "require-unlock toggle explainer")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)
                // Grace window before re-locking — so popping out to copy an address and coming
                // right back doesn't re-prompt. Only relevant while the lock is armed.
                if app.appLock.enabled {
                    Menu {
                        Button { app.appLock.setGraceSeconds(0) } label: {
                            Text("Immediately", bundle: .module, comment: "auto-lock: no grace period") }
                        Button { app.appLock.setGraceSeconds(10) } label: {
                            Text("After 10 seconds", bundle: .module, comment: "auto-lock grace option") }
                        Button { app.appLock.setGraceSeconds(30) } label: {
                            Text("After 30 seconds", bundle: .module, comment: "auto-lock grace option") }
                        Button { app.appLock.setGraceSeconds(60) } label: {
                            Text("After 1 minute", bundle: .module, comment: "auto-lock grace option") }
                        Button { app.appLock.setGraceSeconds(300) } label: {
                            Text("After 5 minutes", bundle: .module, comment: "auto-lock grace option") }
                    } label: {
                        menuRowLabel(Text("Auto-lock", bundle: .module, comment: "auto-lock grace period label"),
                                     autoLockValueText)
                    }
                }
            }
            Section {
                Menu {
                    Button { app.newWalletWordCount = 12 } label: {
                        Text("12 words", bundle: .module, comment: "new-wallet seed length: 12 words") }
                    Button { app.newWalletWordCount = 24 } label: {
                        Text("24 words", bundle: .module, comment: "new-wallet seed length: 24 words") }
                } label: {
                    menuRowLabel(Text("Recovery phrase length", bundle: .module, comment: "new-wallet seed length label"),
                                 newWalletWordCountValueText)
                }
            } header: {
                sectionHeader(Text("New wallets", bundle: .module, comment: "settings section: new wallets"))
            } footer: {
                Text("Length of the recovery phrase generated for new wallets. 12 words is plenty for most wallets; 24 adds extra entropy — more to write down.",
                     bundle: .module, comment: "new-wallet seed length explainer")
            }
            Section(header: sectionHeader(Text("Appearance", bundle: .module, comment: "settings section: appearance"))) {
                Menu {
                    Button { appearance = "" } label: {
                        Text("System", bundle: .module, comment: "appearance: follow system") }
                    Button { appearance = "light" } label: {
                        Text("Light", bundle: .module, comment: "appearance: light mode") }
                    Button { appearance = "dark" } label: {
                        Text("Dark", bundle: .module, comment: "appearance: dark mode") }
                } label: {
                    menuRowLabel(Text("Theme", bundle: .module, comment: "appearance picker label"),
                                 themeValueText)
                }
            }
            Section {
                Menu {
                    // Explicit buttons, not ForEach: ForEach children get a Compose start-inset in a
                    // SkipUI Menu (they render indented vs. flush direct buttons).
                    Button { app.fiatCurrency = .usd } label: { Text(verbatim: FiatCurrency.usd.menuLabel) }
                    Button { app.fiatCurrency = .eur } label: { Text(verbatim: FiatCurrency.eur.menuLabel) }
                    Button { app.fiatCurrency = .gbp } label: { Text(verbatim: FiatCurrency.gbp.menuLabel) }
                    Button { app.fiatCurrency = .jpy } label: { Text(verbatim: FiatCurrency.jpy.menuLabel) }
                } label: {
                    menuRowLabel(Text("Display currency", bundle: .module, comment: "fiat currency picker label"),
                                 Text(verbatim: app.fiatCurrency.menuLabel))
                }
            } header: {
                sectionHeader(Text("Display currency", bundle: .module, comment: "fiat currency section header"))
            } footer: {
                Text("Fiat values appear on mainnet wallets only, priced via Bitfinex.",
                     bundle: .module, comment: "fiat currency section explainer")
            }
            Section(header: sectionHeader(Text("Network", bundle: .module, comment: "settings section: network"))) {
                NavigationLink {
                    NetworkSettingsScreen()
                } label: {
                    Text("Server & privacy", bundle: .module, comment: "settings row → custom endpoint + proxy")
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text0)
                }
            }
            Section(header: sectionHeader(Text("About", bundle: .module, comment: "settings section: about"))) {
                Text(versionString)
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text1)
                NavigationLink {
                    LicensesScreen()
                } label: {
                    Text("Open-source licenses", bundle: .module, comment: "settings row → attributions")
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text0)
                }
            }
            // Dev affordance — the iOS Keychain survives app deletion, so this is the reliable wipe
            // for repeated testing. Returns to the empty state. (Gate behind a debug flag later.)
            Section(header: sectionHeader(Text("Developer", bundle: .module, comment: "settings section: developer"))) {
                Button { app.wipeAllWallets() } label: {
                    Text("Reset all wallet data", bundle: .module, comment: "developer reset button")
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.negative)
                }
                Text("Wipes every wallet from the Keychain + storage on this device.",
                     bundle: .module, comment: "developer reset explainer")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)

                // TEMP (2026-07-21): push-notification dev controls hidden from Settings for now.
                // Restore this block to re-enable the register / token-copy affordances.
                /*
                // Phase 1 push notifications: register the device + reveal the token so we can send a
                // test push (Firebase console for Android; an APNs sender for iOS). Dev-only for now.
                Button { Task { await app.push.register() } } label: {
                    Text(app.push.status == .working ? "Registering…" : "Register for push notifications",
                         bundle: .module, comment: "developer: push register button")
                        .textStyle(.body)
                        .foregroundStyle(Theme.Colors.text0)
                }
                .disabled(app.push.status == .working)

                pushStatusText
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text2)

                if let token = app.push.token {
                    Button { Clipboard.copy(token) } label: {
                        Text("Copy push token", bundle: .module, comment: "developer: copy push token")
                            .textStyle(.body)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    Text(verbatim: token)
                        .font(.jbMono(11, .regular))
                        .foregroundStyle(Theme.Colors.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                */
            }
        }
        .groupedListStyle()
        .navigationTitle(Text("Settings", bundle: .module, comment: "settings screen title"))
        .fullScreenFlow(isPresented: $showBackup) {
            if let vm = app.makeBackupViewModel() {
                BackupFlowView(viewModel: vm)
            }
        }
        .sheet(isPresented: $showSplit) {
            if let vm = app.makeSplitViewModel() {
                SplitCoinsView(viewModel: vm)
            } else {
                // Coins swept between showing the row and tapping (rare) → nothing to drain.
                PlaceholderScreen(heading: "Split coins",
                                  note: "This wallet has no spendable coins to split.")
            }
        }
    }

    /// A settings dropdown row: title + current value, both in our brand fonts. A plain `Picker`
    /// renders its displayed value in the SYSTEM font (and styling the options doesn't change it),
    /// so we use a `Menu` with a hand-built label we fully control. The opened menu items are a
    /// native (platform-drawn) menu; the always-visible row is what we style here.
    /// Section header in our brand font — a plain `Section("…")` title renders in the system font.
    /// `.overline` is the design system's section-overline style (JetBrains Mono, uppercase).
    private func sectionHeader(_ text: Text) -> some View {
        text.textStyle(.overline).foregroundStyle(Theme.Colors.text1)
    }

    private func menuRowLabel(_ title: Text, _ value: Text) -> some View {
        HStack {
            title.textStyle(.body).foregroundStyle(Theme.Colors.text0)
            Spacer()
            value.textStyle(.body).foregroundStyle(Theme.Colors.text1)
            Image(icon: Icon.expand)
                .resizable().scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(Theme.Colors.text2)
        }
    }

    private var themeValueText: Text {
        switch appearance {
        case "light": return Text("Light", bundle: .module, comment: "appearance: light mode")
        case "dark": return Text("Dark", bundle: .module, comment: "appearance: dark mode")
        default: return Text("System", bundle: .module, comment: "appearance: follow system")
        }
    }

    // TEMP (2026-07-21): unused while the push-notification dev controls above are commented out.
    /*
    private var pushStatusText: Text {
        switch app.push.status {
        case .idle: return Text("Not registered", bundle: .module, comment: "push status: not registered")
        case .working: return Text("Registering…", bundle: .module, comment: "push status: working")
        case .registered: return Text("Registered — token below", bundle: .module, comment: "push status: registered")
        case .failed(let message): return Text(verbatim: "Failed: \(message)")
        }
    }
    */

    private var newWalletWordCountValueText: Text {
        app.newWalletWordCount == 24
            ? Text("24 words", bundle: .module, comment: "new-wallet seed length: 24 words")
            : Text("12 words", bundle: .module, comment: "new-wallet seed length: 12 words")
    }

    private var autoLockValueText: Text {
        switch app.appLock.graceSeconds {
        case 0: return Text("Immediately", bundle: .module, comment: "auto-lock: no grace period")
        case 10: return Text("After 10 seconds", bundle: .module, comment: "auto-lock grace option")
        case 30: return Text("After 30 seconds", bundle: .module, comment: "auto-lock grace option")
        case 60: return Text("After 1 minute", bundle: .module, comment: "auto-lock grace option")
        case 300: return Text("After 5 minutes", bundle: .module, comment: "auto-lock grace option")
        default: return Text(verbatim: "\(app.appLock.graceSeconds)s")
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "eCash.com Wallet \(version) (\(build))"
    }
}
