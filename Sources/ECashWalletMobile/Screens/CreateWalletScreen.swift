// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Create a wallet: straight onto the entropy grid (`docs/seed-container-model.md §4`, Jake
/// 2026-11-05). There is no network or address-type decision any more — a wallet is a seed that
/// opens on eCash and switches networks from Home, and every new wallet is native segwit — so the
/// old "New wallet" screen had nothing left but a paragraph and a button. The paragraph moved into
/// the grid's header; this view just owns the session and the create view model.
///
/// The entropy session is drawn when this screen appears — that is what draws the device
/// randomness and timestamp — so leaving and coming back gives a fresh one, same as the old
/// Continue tap did.
struct CreateWalletScreen: View {
    let defaultName: String
    @Environment(AppState.self) var app
    @State var vm: CreateViewModel   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var session: EntropySession

    init(viewModel: CreateViewModel, defaultName: String, wordCount: Int) {
        self.defaultName = defaultName
        _vm = State(initialValue: viewModel)
        _session = State(initialValue: EntropySession(wordCount: wordCount))
    }

    var body: some View {
        // The word count comes from the entropy screen, not Settings: an edited (pasted) string
        // carries its own, and deriving it at the Settings value would refuse it.
        EntropyInputScreen(model: session.model, intro: intro, errorMessage: vm.errorMessage) { field, wordCount in
            vm.entropyField = field
            vm.submit(label: defaultName, wordCount: wordCount)
        }
        .id(session.id)
    }

    private var intro: Text {
        Text("Your keys, your coins. Add your own randomness to the device's, then see the recovery phrase it produces — that phrase is the only way to restore this wallet, and not even we can recover it for you.",
             bundle: .module, comment: "create wallet: self-custody explainer above the entropy grid")
    }
}
