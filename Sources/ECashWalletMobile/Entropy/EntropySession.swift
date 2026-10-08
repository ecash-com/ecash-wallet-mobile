// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One visit to the entropy screen, started by Continue on New wallet.
///
/// Creating it creates the `EntropyViewModel`, and that is what draws the device randomness and
/// freezes the timestamp — so they are drawn on the Continue tap, and backing out and pressing
/// Continue again starts a new session with different randomness. Identity is the `id` alone; it's
/// the item that drives `navigationDestination(item:)`.
@MainActor
struct EntropySession: Identifiable, Hashable {
    let id = UUID()
    let model: EntropyViewModel

    init(wordCount: Int) {
        model = EntropyViewModel(wordCount: wordCount)
    }

    nonisolated static func == (lhs: EntropySession, rhs: EntropySession) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
