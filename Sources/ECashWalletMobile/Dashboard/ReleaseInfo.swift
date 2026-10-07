// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The Releases card: the node build for the dashboard's network, and the newest wallet release.
/// Either may be missing — each comes from its own source.
struct ReleaseInfo: Equatable, Codable, Sendable {
    let node: NodeRelease?
    let wallet: WalletRelease?
}

/// `releases.ecash.com/L1-ecash-bitcoin/<channel>/latest/release.json`.
struct NodeRelease: Equatable, Codable, Sendable {
    let version: String        // "31.1.0"
    let commitShort: String    // "ca64033c1374"
    let channel: String        // "betanet"

    var pageURL: String { "https://releases.ecash.com/L1-ecash-bitcoin/\(channel)/latest/" }
}

/// The newest GitHub release of this app.
struct WalletRelease: Equatable, Codable, Sendable {
    let tag: String            // "v1.3.0_build30"
    let url: String
    let publishedAt: Int64?

    /// "v1.3.0_build30" → "1.3.0 (30)"; anything else is shown as-is.
    var displayVersion: String {
        var t = tag
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.components(separatedBy: "_build")
        guard parts.count == 2, !parts[0].isEmpty, Int(parts[1]) != nil else { return tag }
        return "\(parts[0]) (\(parts[1]))"
    }
}
