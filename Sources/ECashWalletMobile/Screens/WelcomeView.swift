// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// First-launch landing (no wallets yet): brand + the two entry points. Presentational — the
/// buttons call closures supplied by `OnboardingView`, which owns the navigation.
struct WelcomeView: View {
    var onCreate: () -> Void
    var onImport: () -> Void

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            VStack(spacing: Theme.Space.x5) {
                Spacer()
                VStack(spacing: Theme.Space.x5) {
                    Logo(size: 112)
                    Text("eCash.com Wallet", bundle: .module, comment: "app name (product name — usually left untranslated)")
                        .textStyle(.h1)
                        .foregroundStyle(Theme.Colors.text0)
                }
                Spacer()
                VStack(spacing: Theme.Space.x3) {
                    WalletButton(title: "Create new wallet", action: onCreate)
                    WalletButton(title: "Import existing wallet", kind: .secondary, action: onImport)

                    VStack(spacing: Theme.Space.x2) {
                        Text("Your keys never leave this device. By continuing you accept our terms.",
                             bundle: .module, comment: "welcome footer disclaimer")
                            .textStyle(.xs)
                            .foregroundStyle(Theme.Colors.text2)
                            .multilineTextAlignment(.center)
                        legalLinks
                    }
                    .padding(.top, Theme.Space.x1)
                }
            }
            .padding(Theme.Space.gutter)
        }
    }

    /// Terms + privacy, as two real links.
    ///
    /// Deliberately NOT inline markdown links inside the sentence above (`[Terms](https://…)` in a
    /// `LocalizedStringKey`): SwiftUI renders those, but it's precisely the kind of construct that can
    /// come out as literal bracket text on Compose — and a legal link that silently stops being a link
    /// is worse than one that never looked like prose. Two separate `Link`s also give each a real tap
    /// target, which a few underlined words in 11pt type would not.
    private var legalLinks: some View {
        HStack(spacing: Theme.Space.x2) {
            if let terms = LegalLinks.terms {
                Link(destination: terms) {
                    Text("Terms", bundle: .module, comment: "welcome footer → terms of service")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text1)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            if LegalLinks.terms != nil && LegalLinks.privacy != nil {
                Text(verbatim: "·").textStyle(.xs).foregroundStyle(Theme.Colors.text2)
            }
            if let privacy = LegalLinks.privacy {
                Link(destination: privacy) {
                    Text("Privacy Policy", bundle: .module, comment: "welcome footer → privacy policy")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text1)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 44)   // touch target (§8: 44pt minimum)
    }
}
