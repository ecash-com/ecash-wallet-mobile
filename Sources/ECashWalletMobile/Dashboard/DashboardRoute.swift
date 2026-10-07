// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

/// Pushes from the Dashboard's "See all" links. Value-based, registered once at the root (mixing
/// closure and value `NavigationLink`s in one stack misbehaves on iOS — see `SidechainsScreen`).
enum DashboardRoute: Hashable {
    case network
    case news
    case markets
    case coinNews
}
