// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Full-screen lock shown when app-lock is armed and the app is locked (cold launch or returning
/// from background). Auto-attempts device auth on appear; the Unlock button lets the user retry
/// after a cancel, so a dismissed prompt is never a dead-end. All visuals are `Theme` tokens.
struct LockScreen: View {
    @Environment(AppState.self) var app

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(spacing: Theme.Space.x4) {
                Spacer()
                Logo(size: 72)
                Text("eCash.com Wallet")
                    .textStyle(.h2)
                    .foregroundStyle(Theme.Colors.text0)
                HStack(spacing: Theme.Space.x2) {
                    Image(icon: Icon.lock)
                        .resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(Theme.Colors.text2)
                    Text("Locked")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text1)
                }
                Spacer()
                WalletButton(title: app.appLock.authenticating ? "Unlocking…" : "Unlock") {
                    Task { await app.appLock.unlock() }
                }
                .disabled(app.appLock.authenticating)
                .opacity(app.appLock.authenticating ? 0.6 : 1)
            }
            .padding(Theme.Space.gutter)
        }
        // Prompt as soon as the lock appears (cold launch / resume).
        .task { await app.appLock.unlock() }
    }
}
