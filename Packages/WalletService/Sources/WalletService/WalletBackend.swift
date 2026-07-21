// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

#if !SKIP_BRIDGE

import Foundation

/// Which chain backend (index server) an engine talks to. **Internal** module helper (like
/// `Descriptors`/`BIP21`): used by `WalletEngine`/the BDK factory/`WalletManager`, never on the
/// JNI bridge — the app drives backends through bridge-safe `String` setters on `WalletManager`,
/// and the factory protocol takes primitives. (Keeping it public would make skipstone generate a
/// bridge for it.) `electrum` → BDK `ElectrumClient` (`ssl://`/`tcp://`); `esplora` →
/// `EsploraClient` (`http(s)://`). CBF is a future v2. See `docs/backends-and-endpoints.md`.
struct WalletBackend: Equatable, Sendable {
    enum Kind: String, Sendable {
        case electrum
        case esplora

        /// Skip-safe parse of a raw kind string. Use this instead of the synthesized
        /// `Kind(rawValue:)` from OTHER files: a *qualified* `WalletBackend.Kind(rawValue:)` gets
        /// mistranspiled by Skip into an enum-constructor call (`WalletBackend.Kind(rawValue = …)`),
        /// which Kotlin rejects ("Enum types cannot be instantiated"). An explicit switch on the
        /// literal rawValues sidesteps that entirely.
        static func from(_ raw: String) -> Kind? {
            switch raw {
            case "electrum": return .electrum
            case "esplora": return .esplora
            default: return nil
            }
        }
    }

    let kind: Kind
    /// `ssl://host:port` / `tcp://host:port` for Electrum, `https://host/...` for Esplora.
    let url: String
    /// Optional SOCKS5 proxy `host:port` (e.g. `127.0.0.1:9050` for Tor); nil = direct.
    let socks5: String?

    init(kind: Kind, url: String, socks5: String? = nil) {
        self.kind = kind
        self.url = url
        self.socks5 = socks5
    }

    /// Build from the primitive form the factory protocol/WalletManager pass around.
    init(kindRaw: String, url: String, socks5: String?) {
        self.kind = Kind.from(kindRaw) ?? .electrum
        self.url = url
        self.socks5 = socks5
    }
}

#endif // !SKIP_BRIDGE
