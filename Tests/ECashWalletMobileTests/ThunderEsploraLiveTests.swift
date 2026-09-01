// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import ECashWalletMobile

/// The endpoint to test against, or nil to skip the suite. Declared outside it because a
/// `.enabled(if:)` condition can't reference a member of the type it decorates — the macro would
/// resolve circularly.
private var thunderLiveEndpoint: String? {
    ProcessInfo.processInfo.environment["THUNDER_ESPLORA_ENDPOINT"]
}

/// `ThunderEsploraClient` against a **real** drivechain-esplora deployment, over real HTTP.
///
/// Opt-in — set the endpoint to run it:
/// ```
/// THUNDER_ESPLORA_ENDPOINT=https://seed.alpha.ecash.eu.com/thunder swift test --filter Live
/// ```
/// Skipped otherwise, so the default suite stays hermetic and offline.
///
/// **Why this earns its keep even while the index holds no blocks.** Every other test in this area
/// feeds the client canned JSON through the injected `fetch` seam, which proves the parsing but not
/// that we are asking the right server the right thing. These are the checks that only a real
/// deployment can answer: that the routes compose correctly against a service mounted under a path,
/// that the empty-index 404 really is a 404 with that body, that a rejected address really is a 400,
/// and that the address-stats JSON really has the fields we decode. All of that is true today, with
/// nothing indexed.
///
/// Everything needing actual chain data lives in the sibling suites and stays stubbed until the index
/// syncs. Read-only throughout — nothing here broadcasts.
@Suite(.enabled(if: thunderLiveEndpoint != nil))
struct ThunderEsploraLiveTests {

    private func client() throws -> ThunderEsploraClient {
        ThunderEsploraClient(endpoint: try #require(thunderLiveEndpoint))
    }

    /// Index-0 address for the standard test mnemonic. Nobody has ever paid it; it is here to prove
    /// the address routes answer in the shape we decode, not to find coins.
    private static let address = "38VvRdmcQREr1UAcZma98WLFVpAp"

    /// The tip either parses as a height or reports the index as empty. Both are healthy answers, and
    /// which one we get is the live status of the deployment.
    @Test func tipIsAHeightOrAnHonestlyEmptyIndex() async throws {
        do {
            let height = try await client().tipHeight()
            #expect(height >= 0)
        } catch ThunderBackendError.indexEmpty {
            // Expected while the operator is still bringing the index up. The point of the assertion
            // is that it arrives as `.indexEmpty` and NOT as `.network` or `.malformedResponse` —
            // telling the user their connection is broken would send them to fix the wrong thing.
        }
    }

    /// Address stats decode from the real service. This is the route the whole per-address design
    /// leans on, and the one whose real field names we are trusting.
    @Test func addressStatsDecodeFromTheRealService() async throws {
        let info = try await client().addressInfo(Self.address)
        #expect(info.chainStats.txCount >= 0)
        #expect(info.chainStats.fundedTxoCount >= 0)
    }

    /// The UTXO and history routes answer as arrays we can decode — empty, until the index syncs.
    @Test func addressUTXOAndHistoryRoutesDecode() async throws {
        let utxos = try await client().addressUTXOs(Self.address)
        #expect(utxos.count >= 0)
        let txs = try await client().addressTxs(Self.address)
        #expect(txs.count >= 0)
    }

    /// A malformed address is the service's own 400, surfaced as `.server` with its message — proving
    /// the error mapping against a real rejection rather than a stubbed one.
    @Test func aRejectedAddressArrivesAsAServerError() async throws {
        do {
            _ = try await client().addressInfo("notavalidaddress")
            Issue.record("expected the service to reject a malformed address")
        } catch let ThunderBackendError.server(code, message) {
            #expect(code == 400)
            #expect(!message.isEmpty)
        }
    }

    /// The endpoint is mounted under a path, so a trailing slash would double it and 404 every route.
    /// Verified against the real service, because this is exactly the kind of thing a stub can't catch.
    @Test func aTrailingSlashStillResolvesEveryRoute() async throws {
        let endpoint = try #require(thunderLiveEndpoint)
        let info = try await ThunderEsploraClient(endpoint: endpoint + "/").addressInfo(Self.address)
        #expect(info.chainStats.txCount >= 0)
    }
}
