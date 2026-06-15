// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One open-source project we ship — shown on the Settings → "Open-source licenses" screen.
///
/// This is the SINGLE SOURCE OF TRUTH for attributions: to add, remove, or update a credit,
/// edit `OpenSourceLicense.all` below. The screen (`LicensesScreen`) just renders this list, so
/// nothing else needs to change. Keep `license` as an SPDX identifier where one exists.
struct OpenSourceLicense: Identifiable {
    /// Human-readable project name, e.g. "Bitcoin Dev Kit".
    let name: String
    /// SPDX license identifier(s), e.g. "MIT" or "Apache-2.0 / MIT" for dual-licensed projects.
    let license: String
    /// Project (or license) homepage — opened when the row is tapped.
    let url: String

    var id: String { name }
}

extension OpenSourceLicense {
    /// Every third-party library, font, and asset set the app ships. Keep this in sync with
    /// `Package.swift`, the Android `skip.yml` deps, and the bundled fonts/icons.
    static let all: [OpenSourceLicense] = [
        OpenSourceLicense(
            name: "Skip",
            license: "MPL-2.0",
            url: "https://skip.tools"),
        OpenSourceLicense(
            name: "Bitcoin Dev Kit (BDK)",
            license: "Apache-2.0 / MIT",
            url: "https://bitcoindevkit.org"),
        OpenSourceLicense(
            name: "SkipKeychain",
            license: "LGPL-3.0",
            url: "https://source.skip.tools/skip-keychain"),
        OpenSourceLicense(
            name: "swift-qrcode-generator",
            license: "MIT",
            url: "https://github.com/fwcd/swift-qrcode-generator"),
        OpenSourceLicense(
            name: "SkipQRCode",
            license: "LGPL-3.0",
            url: "https://source.skip.tools/skip-qrcode"),
        OpenSourceLicense(
            name: "JetBrains Mono",
            license: "OFL-1.1",
            url: "https://github.com/JetBrains/JetBrainsMono"),
        OpenSourceLicense(
            name: "Space Grotesk",
            license: "OFL-1.1",
            url: "https://github.com/floriankarsten/space-grotesk"),
        OpenSourceLicense(
            name: "Material Symbols",
            license: "Apache-2.0",
            url: "https://github.com/google/material-design-icons"),
    ]
}
