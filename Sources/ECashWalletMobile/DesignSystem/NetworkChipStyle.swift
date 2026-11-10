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
        case .ecashMainnet:
            // The REAL eCash — wears the eCash BRAND amber (`netEcash` = the accent): this is the
            // flagship network of the eCash wallet, and the one that holds real money. Its `bc1…`
            // addresses are byte-identical to real Bitcoin's, so the amber MUST stay visually distinct
            // from Bitcoin's `netMainnet` orange (#F7931A vs #E8A84A) — the chip is the primary
            // safety cue (Golden Rule §6). Dark `accentText` for legible contrast on the amber.
            return NetworkChipStyle(background: Theme.Colors.netEcash,
                                    foreground: Theme.Colors.accentText)
        case .ecash:
            // Alphanet — the first test fork, being retired (the live config no longer lists it as
            // of 2026-10-22). It wore the brand amber until the real fork took it (above): the chip
            // is the only thing telling two eCash chains apart, and the amber now has to mean "real
            // ECX". Slate grey: reads as "old test chain", far from amber, Bitcoin orange, betanet
            // teal, testnet violet and Thunder crimson.
            return NetworkChipStyle(background: Theme.Colors.netEcashLegacy,
                                    foreground: Theme.Colors.netEcashLegacyText)
        case .ecashBeta:
            // eCash **betanet** — teal, NOT the eCash amber. Betanet and alphanet derive IDENTICAL
            // `bc1…` addresses from the same seed (both coin-type `0'`, both Bitcoin-identical), so
            // the chip is the ONLY thing distinguishing them anywhere in the UI — the same argument
            // as amber-vs-Bitcoin-orange above, one step further. Teal is deliberately far from
            // amber, Bitcoin orange, testnet violet and Thunder crimson.
            return NetworkChipStyle(background: Theme.Colors.netEcashTest,
                                    foreground: Theme.Colors.netEcashTestText)
        case .thunder, .thunderMainnet:
            // Thunder — crimson (#DC143C), white text. Deliberately distinct from the `negative`
            // error red so a Thunder chip reads as brand, not danger (Golden Rule §6).
            return NetworkChipStyle(background: Theme.Colors.netThunder,
                                    foreground: Theme.Colors.netThunderText)
        }
    }
}
