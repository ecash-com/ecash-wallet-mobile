// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Failures from a Thunder backend — either wire layer — scrubbed of anything sensitive
/// (Golden Rule §2). Shared by `ThunderRPCClient` (the node's JSON-RPC) and `ThunderEsploraClient`
/// (a drivechain-esplora index), so `ThunderService` handles one error type regardless of which
/// backend a network resolves to.
enum ThunderBackendError: Error, Equatable {
    /// The configured endpoint isn't a usable URL.
    case badURL(String)
    /// The request never completed (offline, DNS, TLS, timeout).
    case network
    /// The server answered with an error — a JSON-RPC error object, or a non-2xx HTTP status.
    case server(code: Int, message: String)
    /// The server answered with something we couldn't parse — `detail` names the field, never content.
    case malformedResponse(String)
    /// The Esplora index is reachable and healthy but has walked no blocks yet, so it can answer no
    /// balance and no history. Distinct from `.network` on purpose: nothing is wrong with the phone or
    /// the endpoint, and telling the user "can't connect" would send them to fix the wrong thing.
    case indexEmpty
}

/// The name this enum had while the node's JSON-RPC was the only Thunder wire layer. Kept so existing
/// call sites and tests read unchanged.
typealias ThunderRPCError = ThunderBackendError
