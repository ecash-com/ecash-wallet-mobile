// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if !os(Android)
import CoreText
#endif

/// Registers the bundled custom fonts at launch so SwiftUI's `Font.custom(_:)` can resolve
/// them by PostScript name on iOS. The `.ttf`s live in the module resource bundle
/// (`Bundle.module`), not the main app bundle, so `Info.plist`/`UIAppFonts` can't see them —
/// we register them with CoreText instead.
///
/// Android needs no registration: SkipUI resolves `Font.custom("Satoshi-Bold")` to the
/// bundled font resource `satoshi_bold` (which is why the files are named that way).
enum FontRegistration {
    static func registerBundledFonts() {
        #if !os(Android)
        var urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        if urls.isEmpty {
            urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        }
        if urls.isEmpty { return }
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
        #endif
    }
}
