// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The single source of truth for the app's visual language (DESIGN.md).
///
/// A caseless namespace — never instantiated. Every view references `Theme.*`; there is no
/// raw hex, font name, spacing number, or radius anywhere else in the codebase.
///
/// Portability (carve-outs over DESIGN.md's iOS-first snippets):
/// - Colors are SwiftUI-native and resolve from the asset catalog (Any = light, Dark
/// appearance). NO UIKit `UIColor { traitCollection }` — Skip maps the catalog to a
/// Compose `ColorScheme` so light/dark works on both platforms with no view-level branching.
/// - Type styles live in `Typography.swift` (`Font.grotesk/plex/mono` + `Theme.Typography`).
/// - Icons are NOT here — they use the Material Symbols `.symbolset` workflow, never SF Symbols.
enum Theme {

    /// Semantic color palette. Names mirror DESIGN.md §1 so its component recipes work verbatim.
    /// Each token resolves a color set in `Resources/Module.xcassets`.
    enum Colors {
        // Surfaces (adaptive light/dark)
        static let bg0 = Color("bg0", bundle: .module) // app background
        static let bg1 = Color("bg1", bundle: .module) // elevated surface
        static let bg2 = Color("bg2", bundle: .module) // card / input
        static let border = Color("border", bundle: .module) // hairlines, dividers

        // Text (adaptive)
        static let text0 = Color("text0", bundle: .module) // primary
        static let text1 = Color("text1", bundle: .module) // secondary / muted
        static let text2 = Color("text2", bundle: .module) // faint / placeholder

        // Brand / action — the single primary-action color. Do not introduce new accents.
        // (Bitcoin-orange placeholder — VERIFY against the real brand.)
        static let accent = Color("accent", bundle: .module)
        static let accentText = Color("accentText", bundle: .module) // text/icon on accent
        static let accentHover = Color("accentHover", bundle: .module)
        static let accentTint = Color("accentTint", bundle: .module) // ~12% wash behind chips
        static let brandAmber = Color("brandAmber", bundle: .module) // the LOGO mark color (distinct from accent)

        // Semantic status — reserved for their meaning only.
        static let positive = Color("positive", bundle: .module) // received / confirmed
        static let negative = Color("negative", bundle: .module) // sent / error / destructive
        static let warning = Color("warning", bundle: .module) // unconfirmed / caution
        static let positiveTint = Color("positiveTint", bundle: .module)
        static let negativeTint = Color("negativeTint", bundle: .module)
        static let warningTint = Color("warningTint", bundle: .module)

        // Network identity. Bitcoin mainnet = its own orange; eCash = the brand amber; testnets =
        // violet. These MUST stay mutually distinguishable — eCash's amber and Bitcoin's orange in
        // particular, since eCash uses byte-identical `bc` addresses (Golden Rule §6).
        static let netMainnet = Color("netMainnet", bundle: .module) // Bitcoin orange #F7931A
        static let netMainnetText = Color("netMainnetText", bundle: .module)
        static let netTestnet = Color("netTestnet", bundle: .module) // high-contrast violet
        static let netTestnetText = Color("netTestnetText", bundle: .module)
        // eCash network chip = the eCash brand amber (== accent); dark text via accentText.
        static let netEcash = Color("netEcash", bundle: .module) // eCash amber #E8A84A
        static let netEcashTest = Color("netEcashTest", bundle: .module)
        static let netThunder = Color("netThunder", bundle: .module) // Thunder crimson #DC143C
        static let netThunderText = Color("netThunderText", bundle: .module) // white
    }

    /// 4-pt spacing grid (DESIGN.md §3).
    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x5: CGFloat = 20
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
        static let x10: CGFloat = 40
        static let x12: CGFloat = 48
        static let gutter: CGFloat = 20 // screen side padding (outside a List)
        static let tap: CGFloat = 44 // minimum hit target
    }

    /// Corner radii (DESIGN.md §3). `md` = default card/input; `lg` = grouped cards/sheets.
    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
        static let pill: CGFloat = 999
    }

    /// Motion — quick, no bounce (DESIGN.md §3). Honor Reduce Motion at call sites.
    enum Motion {
        static let fast: Double = 0.12
        static let base: Double = 0.20
        static let slow: Double = 0.32
        static let ease = Animation.easeOut(duration: base)
        static let press = Animation.easeOut(duration: fast)
    }
}
