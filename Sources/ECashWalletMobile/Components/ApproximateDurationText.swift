// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// A block count as "about 3 months". Singular forms spelled out: plural variants in the string
/// catalog are deferred (memory: fuse-localization-no-string-localized).
struct ApproximateDurationText: View {
    let duration: ApproximateDuration

    var body: some View {
        switch duration {
        case .minutes(let n):
            Text("about \(String(n)) minutes", bundle: .module, comment: "rough duration")
        case .hours(1):
            Text("about an hour", bundle: .module, comment: "rough duration")
        case .hours(let n):
            Text("about \(String(n)) hours", bundle: .module, comment: "rough duration")
        case .days(1):
            Text("about a day", bundle: .module, comment: "rough duration")
        case .days(let n):
            Text("about \(String(n)) days", bundle: .module, comment: "rough duration")
        case .weeks(1):
            Text("about a week", bundle: .module, comment: "rough duration")
        case .weeks(let n):
            Text("about \(String(n)) weeks", bundle: .module, comment: "rough duration")
        case .months(1):
            Text("about a month", bundle: .module, comment: "rough duration")
        case .months(let n):
            Text("about \(String(n)) months", bundle: .module, comment: "rough duration")
        }
    }
}
