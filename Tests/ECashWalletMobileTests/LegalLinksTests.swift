// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The legal URLs are constants, so there is no logic to test — but a typo in one of them ships a
/// dead privacy-policy link, which is the single thing both app stores check by hand. These are
/// cheap guards against that, not tests of behaviour.
@Suite struct LegalLinksTests {

    /// A malformed string would make the accessor nil, and both call sites render *nothing* when it is
    /// — a link that silently disappears rather than one that visibly breaks.
    @Test func bothURLsParse() {
        #expect(LegalLinks.terms != nil)
        #expect(LegalLinks.privacy != nil)
    }

    /// Apple and Play both reject a plain-HTTP privacy policy, and ATS would block the load anyway.
    @Test func bothURLsAreHTTPS() {
        #expect(LegalLinks.terms?.scheme == "https")
        #expect(LegalLinks.privacy?.scheme == "https")
    }

    /// They are different documents; pointing both rows at one page is the likeliest copy-paste slip.
    @Test func termsAndPrivacyAreDistinct() {
        #expect(LegalLinks.termsURLString != LegalLinks.privacyURLString)
    }

    /// The store listing carries the same privacy URL in `Darwin/fastlane/metadata/en-US/privacy_url.txt`.
    /// Pinned so a change here is a deliberate change in both places rather than a silent divergence.
    @Test func privacyURLMatchesTheStoreListing() {
        #expect(LegalLinks.privacyURLString == "https://ecash.com/privacy")
    }
}
