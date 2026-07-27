// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// A wallet's balance as shown in list rows — the wallet manager and the send destination picker.
///
/// Amounts are mono with the unit label; a wallet that has never synced on this device shows
/// **"Not synced"** rather than `0`, because those are different facts and only one of them is
/// something we actually know (see `WalletBalanceSummary`). One component so both lists say it the
/// same way.
struct WalletBalanceLabel: View {
    let balance: WalletBalanceSummary
    let unitLabel: String

    var body: some View {
        if let text = balance.displayText(unitLabel: unitLabel) {
            Text(verbatim: text)              // amounts are data, never translated
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text1)
        } else {
            Text("Not synced", bundle: .module,
                 comment: "wallet list: balance is unknown because the wallet has never synced here")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
    }
}
