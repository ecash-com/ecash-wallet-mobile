// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The app's legal documents, in one place.
///
/// Both stores require a reachable privacy policy — Apple checks the `privacy_url` in App Store
/// Connect, Play checks the one in the Play Console listing — and both expect the app itself to be
/// able to surface it, not just the listing. These are referenced from two places: the first-launch
/// `WelcomeView` (where the user is accepting them by continuing) and Settings → About (where a user
/// who has already onboarded can still find them).
///
/// Kept as a type rather than inline strings so the URL appears once. `Darwin/fastlane/metadata/en-US/
/// privacy_url.txt` carries the same value for the store listing — if one changes, change both.
enum LegalLinks {
    static let termsURLString = "https://ecash.com/terms"
    static let privacyURLString = "https://ecash.com/privacy"

    /// Non-optional accessors would need a force-unwrap, which §10 forbids. These are constants that
    /// parse today, but a typo in an edit shouldn't crash the launch screen — call sites that get nil
    /// simply render nothing tappable.
    static var terms: URL? { URL(string: termsURLString) }
    static var privacy: URL? { URL(string: privacyURLString) }
}
