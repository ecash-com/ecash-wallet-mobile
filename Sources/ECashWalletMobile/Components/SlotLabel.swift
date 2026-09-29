// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// "Slot 9": the one unambiguous identity a sidechain has. Small and secondary.
struct SlotLabel: View {
    let slot: Int

    var body: some View {
        Text("Slot \(String(slot))", bundle: .module, comment: "sidechain slot number; %@ is 0-255")
            .textStyle(.xs)
            .foregroundStyle(Theme.Colors.text2)
    }
}
