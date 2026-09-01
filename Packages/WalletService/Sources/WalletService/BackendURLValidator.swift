// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Syntactic validation for a user-entered backend URL.
///
/// The scheme isn't cosmetic — it selects the transport the client will actually attempt. BDK's
/// `ElectrumClient` speaks the Electrum protocol over a raw TCP socket (`tcp://`) or the same wrapped
/// in TLS (`ssl://`); `EsploraClient` speaks HTTP(S). Hand either the other's URL and it doesn't fall
/// back — it fails, or worse, hangs until timeout looking like a dead server.
///
/// Deliberately syntax-only. Whether the host exists, answers, and serves the RIGHT CHAIN is a live
/// question and belongs to the Test-connection probe; this just stops obviously-wrong input from
/// being saved. Pure and Skip-safe so it's unit-tested on both platforms.
public enum BackendURLValidator {

    /// nil = acceptable. Otherwise a short, user-facing reason.
    public static func validationMessage(kind: String, url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }   // empty means "clear the override", handled by the caller

        // Whitespace inside a URL is always a paste accident, and would otherwise reach the client.
        if trimmed.contains(" ") { return "Address can't contain spaces." }

        guard let separator = trimmed.range(of: "://") else {
            return kind == "electrum"
                ? "Start with ssl:// or tcp://"
                : "Start with https:// or http://"
        }
        let scheme = String(trimmed[trimmed.startIndex..<separator.lowerBound]).lowercased()
        let rest = String(trimmed[separator.upperBound...])
        if rest.isEmpty { return "Add a server address after \(scheme)://" }

        switch kind {
        case "electrum":
            guard scheme == "ssl" || scheme == "tcp" else {
                return "Electrum servers use ssl:// or tcp://, not \(scheme)://"
            }
            // Electrum has no default port, so the client can't guess one — an address without a
            // port fails to connect rather than falling back to something sensible.
            return electrumHostPortMessage(rest)
        case "esplora":
            guard scheme == "https" || scheme == "http" else {
                return "Esplora servers use https:// or http://, not \(scheme)://"
            }
            // `components(separatedBy:)`, not `split(separator:).first.map(String.init)` — a bare
            // `String.init` function reference doesn't transpile ("actual type is String.Companion").
            let host = rest.components(separatedBy: "/").first ?? ""
            return host.isEmpty ? "Add a server address after \(scheme)://" : nil
        case "thunder", "thunder-esplora":
            // Both Thunder wire layers are HTTP: the node speaks JSON-RPC, the drivechain-esplora
            // index speaks Esplora REST. Same scheme rules as Esplora either way. Without this branch
            // the switch fell to "Unknown server type" and setBackendOverride silently refused every
            // Thunder endpoint — harmless while Thunder was hidden from the pickers, a silent
            // failure the moment it wasn't.
            guard scheme == "https" || scheme == "http" else {
                return "Thunder servers use https:// or http://, not \(scheme)://"
            }
            // A path IS expected here — the index is mounted under one (`/thunder`), and the routes
            // hang off it. So only the host is checked, exactly as for Esplora.
            let host = rest.components(separatedBy: "/").first ?? ""
            return host.isEmpty ? "Add a server address after \(scheme)://" : nil
        default:
            return "Unknown server type."
        }
    }

    /// Electrum needs `host:port`. Split on the LAST colon so IPv6 literals (`[::1]:50002`) survive.
    private static func electrumHostPortMessage(_ rest: String) -> String? {
        // A path is meaningless for a raw socket, and usually means an Esplora URL pasted here.
        if rest.contains("/") { return "Electrum addresses are host:port, with no path." }
        guard let colon = rest.lastIndex(of: ":") else {
            return "Add a port, e.g. host:50002"
        }
        let host = String(rest[rest.startIndex..<colon])
        let port = String(rest[rest.index(after: colon)...])
        if host.isEmpty { return "Add a server address before the port." }
        guard let portValue = Int(port), portValue > 0, portValue <= 65535 else {
            return "Port must be a number between 1 and 65535."
        }
        return nil
    }

    /// Convenience for call sites that only need a yes/no.
    public static func isAcceptable(kind: String, url: String) -> Bool {
        validationMessage(kind: kind, url: url) == nil
    }
}

#endif // !SKIP_BRIDGE
