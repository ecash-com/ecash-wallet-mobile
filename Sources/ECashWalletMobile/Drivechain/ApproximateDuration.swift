// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A block count as a coarse human duration, at the 10-minute target spacing. Deliberately rough:
/// it's for "about 3 months", never for a deadline.
enum ApproximateDuration: Equatable {
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case weeks(Int)
    case months(Int)

    static let minutesPerBlock = 10

    init(blocks: Int) {
        let minutes = max(0, blocks) * Self.minutesPerBlock
        let hours = minutes / 60
        let days = hours / 24
        switch minutes {
        case ..<60: self = .minutes(max(1, minutes))
        case ..<(60 * 48): self = .hours(Int((Double(minutes) / 60).rounded()))
        case ..<(60 * 24 * 14): self = .days(Int((Double(hours) / 24).rounded()))
        case ..<(60 * 24 * 60): self = .weeks(Int((Double(days) / 7).rounded()))
        default: self = .months(Int((Double(days) / 30.4).rounded()))
        }
    }
}
