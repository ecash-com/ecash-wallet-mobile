// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// First-launch flow shown when there are no wallets: `Welcome → Create wallet (self-custody
/// confirm) → generate`. On success `AppState.hasWallets` flips and `RootView` re-roots to the
/// main shell — so there's no "done" step here; the whole stack just unmounts.
///
/// Uses value-based navigation (`NavigationStack(path:)` + `.navigationDestination(for:)`), which
/// is the Skip-supported shape.
struct OnboardingView: View {
    @Environment(AppState.self) var app
    @State var path: [OnboardingRoute] = []   // not `private` — Fuse @State bridging rule

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(onCreate: { path.append(.createConfirm) },
                        onImport: { path.append(.importWallet) })
                .navigationDestination(for: OnboardingRoute.self) { route in
                    switch route {
                    case .createConfirm:
                        CreateConfirmView(viewModel: app.makeCreateViewModel(),
                                          defaultName: app.nextDefaultWalletName)
                    case .importWallet:
                        ImportWalletView(viewModel: app.makeImportViewModel(),
                                         defaultName: app.nextDefaultWalletName)
                    }
                }
        }
    }
}

enum OnboardingRoute: Hashable {
    case createConfirm
    case importWallet
}
