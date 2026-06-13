// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The app's icon vocabulary — semantic names mapped to Material Symbols `.symbolset`
/// resources in `Resources/Icons.xcassets`. Reference icons by these names so call sites
/// never carry raw asset strings, and the same `.symbolset` renders identically on iOS and
/// Android. NEVER use SF Symbols (`Image(systemName:)` / `Label(_, systemImage:)`) — they
/// render blank on Android (skip-icons).
///
/// Swapping icon sets later (e.g. to Lucide) is a one-file change: replace the SVGs in
/// `Icons.xcassets` and update the asset-name strings below. Call sites use the semantic
/// `Icon.*` names + `Image(icon:)`, so none of them change.
enum Icon {
    // Tabs
    static let wallet = "account_balance_wallet"
    static let activity = "format_list_bulleted"
    static let settings = "settings"

    // Money actions
    static let send = "north_east"
    static let receive = "south_west"
    static let swap = "swap_horiz"
    static let buy = "credit_card"
    static let scan = "qr_code_scanner"
    static let qr = "qr_code"
    static let backspace = "backspace"

    // General actions
    static let copy = "content_copy"
    static let share = "share"
    static let refresh = "refresh"
    static let add = "add"
    static let more = "more_horiz"
    static let search = "search"

    // Navigation
    static let back = "chevron_left"
    static let disclosure = "chevron_right"
    static let expand = "expand_more"
    static let close = "close"
    static let check = "check"

    // Status
    static let pending = "schedule"
    static let caution = "warning"

    // Security & wallet management
    static let backup = "verified_user"
    static let key = "key"
    static let lock = "lock"
    static let reveal = "visibility"
    static let hide = "visibility_off"
    static let remove = "delete"
    static let rename = "edit"
    static let importWallet = "download"
    static let info = "info"

    // Theme
    static let dark = "dark_mode"
    static let light = "light_mode"
}

extension Image {
    /// A bundled Material Symbol icon, e.g. `Image(icon: Icon.send)`.
    /// Resolves `Icons.xcassets/<name>.symbolset` from the module bundle.
    init(icon name: String) {
        self.init(name, bundle: .module)
    }

    /// Tab-bar icon sizing. Material Symbol images render oversized in Compose's
    /// NavigationBar, so on Android we shrink them; iOS sizes tab icons natively.
    func tabSized() -> some View {
        #if os(Android)
        self.resizable().scaledToFit().frame(width: 16, height: 16)
        #else
        self
        #endif
    }
}
