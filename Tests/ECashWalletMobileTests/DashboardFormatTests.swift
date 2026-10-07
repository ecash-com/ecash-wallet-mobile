// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import ECashWalletMobile

@Suite struct DashboardFormatTests {
    static let us = Locale(identifier: "en_US")

    @Test func pricesKeepSignificantDigitsAsTheyShrink() {
        #expect(DashboardFormat.usd(83_196.4, locale: Self.us) == "$83,196")
        #expect(DashboardFormat.usd(301.41, locale: Self.us) == "$301.41")
        #expect(DashboardFormat.usd(2.567, locale: Self.us) == "$2.57")
        #expect(DashboardFormat.usd(0.5432, locale: Self.us) == "$0.5432")
        #expect(DashboardFormat.usd(0.000007569, locale: Self.us) == "$0.000007569")
    }

    @Test func compactUnits() {
        #expect(DashboardFormat.compactUSD(38_090_000_000, locale: Self.us) == "$38.1B")
        #expect(DashboardFormat.compactUSD(4_521.23, locale: Self.us) == "$4.5K")
        #expect(DashboardFormat.compact(1_670_000_000_000, locale: Self.us) == "1.7T")
        #expect(DashboardFormat.compact(812, locale: Self.us) == "812")
    }

    @Test func changeCarriesADirectionNotJustAColour() {
        #expect(DashboardFormat.percentChange(4.68, locale: Self.us) == "▲ 4.68%")
        #expect(DashboardFormat.percentChange(-18.8, locale: Self.us) == "▼ 18.80%")
        #expect(DashboardFormat.percentChange(0, locale: Self.us) == "0.00%")
        #expect(DashboardFormat.percentChange(7.9417, locale: Self.us) == "▲ 7.94%")   // rounded, not truncated
    }

    @Test func chainNumbers() {
        #expect(DashboardFormat.integer(971_335, locale: Self.us) == "971,335")
        #expect(DashboardFormat.tps(97_726.0 / 86_400.0, locale: Self.us) == "1.131")
        #expect(DashboardFormat.bytes(995_945, locale: Self.us) == "995.9 kB")
        #expect(DashboardFormat.bytes(1_200_000, locale: Self.us) == "1.2 MB")
        #expect(DashboardFormat.bytes(512, locale: Self.us) == "512 B")
    }

    @Test func ages() {
        #expect(DashboardFormat.age(since: 100, now: 130) == "now")
        #expect(DashboardFormat.age(since: 0, now: 240) == "4m")
        #expect(DashboardFormat.age(since: 0, now: 7_300) == "2h")
        #expect(DashboardFormat.age(since: 0, now: 3 * 86_400) == "3d")
        #expect(DashboardFormat.age(since: 500, now: 100) == "now")   // a future-stamped block
    }
}
