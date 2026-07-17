// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Per-network chip colors — a **code-level config, not user-facing**. Every network shows a chip so
/// its identity is unmistakable on every money surface (Golden Rule §6); each network gets its own
/// color, set here. This is the one place to change a network's chip color (and where future eCash
/// networks slot in). Colors resolve to `Theme` colorsets (Skip-safe float components).
struct NetworkChipStyle {
    let background: Color
    let foreground: Color

    /// The chip style for a network. One explicit case per network so each is an independent knob.
    static func style(for network: WalletNetwork) -> NetworkChipStyle {
        switch network {
        case .bitcoin:
            // Real Bitcoin — the iconic Bitcoin orange (#F7931A).
            return NetworkChipStyle(background: Theme.Colors.netMainnet,
                                    foreground: Theme.Colors.netMainnetText)
        case .signet:
            return NetworkChipStyle(background: Theme.Colors.netTestnet,
                                    foreground: Theme.Colors.netTestnetText)
        case .ecash:
            // eCash (drynet2) wears the eCash BRAND orange (`netEcash` = the amber accent) — this is
            // the flagship network of the eCash wallet. NOTE: its `bc1…` addresses are byte-identical
            // to real Bitcoin mainnet, so this amber MUST stay visually distinct from Bitcoin's
            // `netMainnet` orange (#F7931A vs #E8A84A) — the chip is the primary safety cue (Golden
            // Rule §6). Dark `accentText` for legible contrast on the amber.
            return NetworkChipStyle(background: Theme.Colors.netEcash,
                                    foreground: Theme.Colors.accentText)
        }
    }
}
