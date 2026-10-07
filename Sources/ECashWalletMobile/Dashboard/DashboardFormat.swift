// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Number formatting for the dashboard. Pure and locale-parameterised so it's tested exactly; views
/// pass `.current`. These are market/chain figures — never wallet amounts, which format through
/// `Amount` (CLAUDE.md §6).
enum DashboardFormat {
    /// "$83,196" / "$301.41" / "$2.57" / "$0.000007569": more decimals as the price shrinks, so a
    /// sub-cent asset still shows significant digits.
    static func usd(_ value: Double, locale: Locale = .current) -> String {
        let magnitude = abs(value)
        let digits: Int
        if magnitude >= 1_000 { digits = 0 }
        else if magnitude >= 1 { digits = 2 }
        else if magnitude >= 0.01 { digits = 4 }
        else if magnitude > 0 {
            // Enough decimals for 4 significant figures.
            digits = min(12, Int((-log10(magnitude)).rounded(.down)) + 4)
        } else { digits = 2 }
        return "$" + decimal(value, fractionDigits: digits, locale: locale)
    }

    /// "$38.1B" / "$259.3M" / "$4.5K" / "$812".
    static func compactUSD(_ value: Double, locale: Locale = .current) -> String {
        "$" + compact(value, locale: locale)
    }

    /// "1.67T" / "38.1B" / "4.5K" / "812".
    static func compact(_ value: Double, locale: Locale = .current) -> String {
        let magnitude = abs(value)
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where magnitude >= scale {
            return decimal(value / scale, fractionDigits: 1, locale: locale) + suffix
        }
        return decimal(value, fractionDigits: 0, locale: locale)
    }

    /// "971,335" — grouped integer.
    static func integer(_ value: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "1.131" — throughput, three decimals.
    static func tps(_ value: Double, locale: Locale = .current) -> String {
        decimal(value, fractionDigits: 3, locale: locale)
    }

    /// "▲ 4.68%" / "▼ 3.73%" / "0.00%". Arrow plus sign so the direction never relies on colour alone.
    static func percentChange(_ value: Double, locale: Locale = .current) -> String {
        let body = decimal(abs(value), fractionDigits: 2, locale: locale) + "%"
        if value > 0.004 { return "▲ " + body }
        if value < -0.004 { return "▼ " + body }
        return body
    }

    /// "995.9 kB" / "2.2 kB" / "1.2 MB" — decimal units, as the explorer shows them.
    static func bytes(_ value: Int64, locale: Locale = .current) -> String {
        let v = Double(value)
        if v >= 1_000_000 { return decimal(v / 1_000_000, fractionDigits: 1, locale: locale) + " MB" }
        if v >= 1_000 { return decimal(v / 1_000, fractionDigits: 1, locale: locale) + " kB" }
        return "\(value) B"
    }

    /// "now" / "4m" / "2h" / "3d" since `epoch`. Compact, for row metadata.
    static func age(since epoch: Int64, now: Int64) -> String {
        let seconds = max(now - epoch, 0)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    /// "05 Oct" — the news timeline's date column.
    static func dayMonth(_ epoch: Int64, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("ddMMM")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// "15:25" — "updated" stamps.
    static func time(_ epoch: Int64, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    static func decimal(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        // Round first: Android's Foundation `NumberFormatter` ignores `maximumFractionDigits`
        // (7.9417 printed as "7.942" with max 2), so the formatter only pads and groups.
        var scale = 1.0
        for _ in 0..<fractionDigits { scale *= 10 }
        let value = (value * scale).rounded() / scale
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
