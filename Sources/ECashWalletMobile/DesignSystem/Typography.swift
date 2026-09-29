// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// MARK: - Font families (DECIDED 2026-06-11)
//
// Two-font system: **Space Grotesk** for display/headings, **JetBrains Mono** for body, labels,
// and all mono/numeric content (addresses, amounts). IBM Plex was dropped. Every piece of text
// in the app uses these via `.textStyle(...)` — no system fonts anywhere (Jake's direction).
// Bundled in BOTH Resources/Fonts (iOS) and Android/app/src/main/res/font (Android).

extension Font {
    /// Space Grotesk — display & headings.
    static func grotesk(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom(groteskPS(weight), size: size)
    }
    /// JetBrains Mono — body, labels, addresses, amounts.
    static func jbMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(jbMonoPS(weight), size: size)
    }

    private static func groteskPS(_ w: Font.Weight) -> String {
        switch w {
        case .medium: return "SpaceGrotesk-Medium"
        case .semibold: return "SpaceGrotesk-SemiBold"
        case .bold, .heavy, .black: return "SpaceGrotesk-Bold"
        default: return "SpaceGrotesk-Regular"
        }
    }
    private static func jbMonoPS(_ w: Font.Weight) -> String {
        switch w {
        case .medium: return "JetBrainsMono-Medium"
        case .semibold, .bold: return "JetBrainsMono-SemiBold"   // SemiBold is the heaviest bundled
        default: return "JetBrainsMono-Regular"
        }
    }
}

// MARK: - Type scale

extension Theme {
    /// Named text styles. Headings are Space Grotesk; everything else is JetBrains Mono.
    /// Apply with `.textStyle(.h1)` / `.textStyle(.button)` so font, tracking, and case all
    /// come from here — no ad-hoc fonts at call sites. Numbers need nothing extra: JetBrains Mono is
    /// fixed-width already (and `.monospacedDigit()` doesn't compile on Fuse-Android).
    enum TextStyle {
        case display   // hero balance — Space Grotesk
        case h1        // screen titles — Space Grotesk
        case h2        // section heads — Space Grotesk
        case h3        // row titles — Space Grotesk
        case button    // button labels — JetBrains Mono semibold
        case body      // default copy — JetBrains Mono
        case sm        // secondary UI — JetBrains Mono
        case xs        // captions — JetBrains Mono
        case overline  // uppercase labels — JetBrains Mono
        case mono      // addresses, txids, seeds — JetBrains Mono

        var font: Font {
            switch self {
            case .display:  return .grotesk(40, .bold)
            case .h1:       return .grotesk(28, .semibold)
            case .h2:       return .grotesk(22, .semibold)
            case .h3:       return .grotesk(18, .semibold)
            case .button:   return .jbMono(16, .semibold)
            case .body:     return .jbMono(15, .regular)
            case .sm:       return .jbMono(13, .regular)
            case .xs:       return .jbMono(12, .medium)
            case .overline: return .jbMono(11, .semibold)
            case .mono:     return .jbMono(14, .regular)
            }
        }

        var tracking: CGFloat {
            switch self {
            case .display:  return -0.8
            case .h1:       return -0.5
            case .overline: return 0.9
            default:        return 0
            }
        }

        var isUppercase: Bool { self == .overline }
    }
}

extension View {
    /// Apply a `Theme.TextStyle` (font + tracking + case) consistently.
    func textStyle(_ style: Theme.TextStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}
