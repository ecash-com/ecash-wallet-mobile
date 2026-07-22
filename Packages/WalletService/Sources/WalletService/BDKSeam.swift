// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Conversion helpers across the bdk-swift ⇄ bdk-android binding divergence (enum spelling:
// Swift camelCase vs Kotlin SCREAMING_SNAKE). This is the ONE place that `#if SKIP`-splits on it;
// `WalletEngine` and `BDKWalletEngineFactory` call these so their bodies stay single-shaped.
//
// They live as STATIC members of a named type (not top-level funcs) ON PURPOSE: in the Fuse app's
// build, a cross-FILE top-level Swift function transpiles to a Kotlin `FileKt` facade whose
// resolution from another file is unreliable (compiles in the standalone package, intermittently
// "Unresolved reference" in the app export). Static members of a named type compile to a real
// Kotlin class and resolve reliably cross-file. Excluded from the bridge pass (BDK-typed returns).

import Foundation
#if !SKIP_BRIDGE
#if !os(Android)
import BitcoinDevKit
#elseif SKIP
import org.bitcoindevkit.__
#endif

// `public` so the transpiled Kotlin resolves it cross-file (a `WalletService`-internal declaration
// is NOT reliably reachable from a sibling file's generated Kotlin under `bridging: true` — and
// that applies to MEMBERS too, not just the type: internal member funcs compiled fine on warm
// incremental state but broke clean app-export builds with "Cannot access … it is internal in
// BDKSeam.Companion", 2026-06-12). So the type AND its member funcs are `public`, while `// SKIP
// @nobridge` keeps the whole thing OUT of the JNI bridge — its members expose BDK types
// (`Network`/`WordCount`/`KeychainKind`) that aren't bridgeable. The whole file is
// `#if !SKIP_BRIDGE`, so the bridge compile never sees the BDK references; on Apple it's a normal
// in-module reference.
// SKIP @nobridge
public enum BDKSeam {
    public static func network(_ network: WalletNetwork) -> Network {
        #if SKIP
        switch network {
        case .bitcoin:  return Network.BITCOIN
        case .signet:   return Network.SIGNET
        // eCash (drynet2) is byte-identical to Bitcoin (mainnet `bc` HRP, coin-type 0');
        // separated from Bitcoin only by its backend, so BDK sees it as BITCOIN.
        case .ecash:    return Network.BITCOIN
        // Thunder never touches BDK (the facade routes it to ThunderService) — unreachable; mapped
        // to BITCOIN only to keep the switch exhaustive.
        case .thunder:  return Network.BITCOIN
        }
        #else
        switch network {
        case .bitcoin:  return Network.bitcoin
        case .signet:   return Network.signet
        case .ecash:    return Network.bitcoin
        case .thunder:  return Network.bitcoin   // unreachable — Thunder doesn't use BDK
        }
        #endif
    }

    public static func wordCount(_ wordCount: Int) -> WordCount {
        #if SKIP
        return wordCount == 24 ? WordCount.WORDS24 : WordCount.WORDS12
        #else
        return wordCount == 24 ? WordCount.words24 : WordCount.words12
        #endif
    }

    public static func externalKeychain() -> KeychainKind {
        #if SKIP
        return KeychainKind.EXTERNAL
        #else
        return KeychainKind.external
        #endif
    }

    public static func internalKeychain() -> KeychainKind {
        #if SKIP
        return KeychainKind.INTERNAL
        #else
        return KeychainKind.internal
        #endif
    }
}
#endif
