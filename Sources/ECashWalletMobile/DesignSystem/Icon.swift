// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The app's icon vocabulary. Each icon carries a Material Symbols `.symbolset` name (used on
/// Android, and on iOS as a fallback) plus an OPTIONAL SF Symbol name used on iOS only.
///
/// Why both: SF Symbols render natively and perfectly-sized in iOS chrome (tab bars etc.), while
/// Android has no SF Symbols — so `Image(icon:)` picks `sf` on iOS and the Material `.symbolset` on
/// Android. SF Symbols are gated behind `#if os(iOS)`, so they never reach the Android build (where
/// `Image(systemName:)` renders blank). Icons with `sf == nil` use the `.symbolset` on both
/// platforms (the prior behavior) — add SF names incrementally as desired.
///
/// NEVER call `Image(systemName:)` directly in shared UI — go through `Image(icon:)` so the Android
/// fallback is always present.
struct Icon {
    /// Material Symbols `.symbolset` resource name (Android + iOS fallback).
    let material: String
    /// SF Symbol name (iOS only). `nil` → use the `.symbolset` on iOS too.
    let sf: String?

    init(_ material: String, sf: String? = nil) {
        self.material = material
        self.sf = sf
    }

    // Tabs (outlined = unselected; *Fill = selected, Material 3 style). SF Symbols on iOS.
    static let wallet = Icon("account_balance_wallet", sf: "wallet.bifold")
    static let walletFill = Icon("account_balance_wallet_fill", sf: "wallet.bifold.fill")
    static let activity = Icon("format_list_bulleted", sf: "list.bullet")
    static let activityFill = Icon("format_list_bulleted_fill", sf: "list.bullet")
    static let settings = Icon("settings", sf: "gearshape")
    static let settingsFill = Icon("settings_fill", sf: "gearshape.fill")
    static let news = Icon("newspaper", sf: "newspaper")
    static let newsFill = Icon("newspaper", sf: "newspaper.fill")

    // Money actions
    static let send = Icon("north_east")
    static let receive = Icon("south_west")
    static let swap = Icon("swap_horiz")
    static let buy = Icon("credit_card")
    static let scan = Icon("qr_code_scanner")
    static let qr = Icon("qr_code")
    static let backspace = Icon("backspace")
    /// Signet faucet ("get test coins"). iOS uses the SF Symbol `drop.fill`; Android uses the
    /// vendored `water_drop` Material symbolset (filled, to match).
    static let faucet = Icon("water_drop", sf: "drop.fill")

    // General actions
    static let copy = Icon("content_copy")
    static let share = Icon("share")
    /// Open an external link. iOS uses the SF Symbol `link`; Android falls back to the `share`
    /// symbolset until a Material `link.symbolset` is vendored (TODO).
    static let link = Icon("share", sf: "link")
    static let refresh = Icon("refresh")
    static let add = Icon("add")
    static let more = Icon("more_horiz")
    static let search = Icon("search")
    /// Topic manager / feed filter — sliders/adjust glyph (SF `slider.horizontal.3`; Android reuses
    /// the `filter_list` lines, visually close).
    static let topics = Icon("filter_list", sf: "slider.horizontal.3")
    /// Sort/order toggle — SF up/down arrows on iOS; reuses the `swap_horiz` glyph on Android.
    static let sort = Icon("swap_horiz", sf: "arrow.up.arrow.down")
    /// Compose / write a post — SF compose box on iOS; reuses the `edit` pencil glyph on Android.
    static let compose = Icon("edit", sf: "square.and.pencil")

    // Navigation
    static let back = Icon("chevron_left")
    static let disclosure = Icon("chevron_right")
    static let expand = Icon("expand_more")
    static let close = Icon("close")
    static let check = Icon("check")

    // Status
    static let pending = Icon("schedule")
    static let caution = Icon("warning")

    // Security & wallet management
    static let backup = Icon("verified_user")
    static let key = Icon("key")
    static let lock = Icon("lock")
    static let reveal = Icon("visibility")
    static let hide = Icon("visibility_off")
    static let remove = Icon("delete")
    static let rename = Icon("edit")
    static let importWallet = Icon("download")
    static let info = Icon("info")

    // Theme
    static let dark = Icon("dark_mode")
    static let light = Icon("light_mode")
}

extension Image {
    /// Render an `Icon`: the SF Symbol on iOS (when set), the Material `.symbolset` on Android (and
    /// on iOS when no SF name). The `#if os(iOS)` gate keeps `Image(systemName:)` out of the Android
    /// build entirely.
    init(icon: Icon) {
        #if os(iOS)
        if let sf = icon.sf {
            self.init(systemName: sf)
        } else {
            self.init(icon.material, bundle: .module)
        }
        #else
        self.init(icon.material, bundle: .module)
        #endif
    }

    /// Tab-bar icon sizing. Material Symbol images render oversized in Compose's NavigationBar and
    /// crowd the selected-item pill indicator, so on Android we shrink them; iOS sizes tab icons
    /// natively (SF Symbols included).
    func tabSized() -> some View {
        #if os(Android)
        self.resizable().scaledToFit().frame(width: 12, height: 12)
        #else
        self
        #endif
    }
}
