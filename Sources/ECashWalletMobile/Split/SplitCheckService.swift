// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if os(Android)
import FoundationNetworking   // URLSession lives here on Fuse-Android (the host build hides it)
#endif
import WalletService

/// What Bitcoin says about one of our eCash coins.
enum SplitCoinStatus: String, Sendable {
    /// The same outpoint is live on Bitcoin → one coin on two chains → **needs splitting**.
    case shared
    /// Bitcoin has never heard of it, or already spent it → a replay is impossible → **safe**.
    case chainSpecific
    /// We couldn't ask (no Esplora backend, network error, malformed reply). Never guessed.
    case unknown
}

/// Resolves whether eCash coins are still shared with Bitcoin, by asking a Bitcoin backend about the
/// exact same outpoints.
///
/// **Why this exists.** Confirmation height is only a proxy. eCash's replay marker is permissive, not
/// mandatory — `tx_verify.cpp` merely *treats* the magic nLockTime as final — so an ordinary
/// Bitcoin-valid transaction still confirms on eCash, and its outputs then exist on BOTH chains at
/// post-fork heights. Any wallet other than ours produces exactly that. Height-based classification
/// therefore under-reports, which is the dangerous direction: the user is told they're separated,
/// and their next spend moves their BTC too.
///
/// It also over-reports in the other direction — a pre-fork coin already spent on Bitcoin can't be
/// replayed onto (that would be a double-spend), so it needs no split despite its height.
///
/// **Read-only.** This only ever issues HTTP GETs against a Bitcoin Esplora. It builds no
/// transaction, touches no key, and cannot move anyone's BTC.
struct SplitCheckService {
    /// Bitcoin Esplora base URL, e.g. `https://esplora.mainnet.drivechain.info` (no trailing slash,
    /// ROOT path — this deployment does NOT use an `/api` prefix).
    let esploraBaseURL: String
    var session: URLSession = .shared

    /// Esplora's outspend endpoint answers both halves of the question in one call: whether Bitcoin
    /// knows the transaction at all (404 if not), and whether that specific output is still unspent.
    private func outspendURL(txid: String, vout: Int32) -> URL? {
        URL(string: "\(esploraBaseURL.trimmedTrailingSlash)/tx/\(txid)/outspend/\(vout)")
    }

    /// Classify one outpoint. Never throws — an unreachable backend yields `.unknown`, because
    /// "we couldn't check" and "it's safe" must never be the same answer on a money screen.
    func status(txid: String, vout: Int32) async -> SplitCoinStatus {
        guard let url = outspendURL(txid: txid, vout: vout) else { return .unknown }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            // 404 → Bitcoin has no such transaction. It only ever existed on eCash, so nothing can
            // replay: chain-specific.
            if http.statusCode == 404 { return .chainSpecific }
            guard http.statusCode == 200 else { return .unknown }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let spent = json["spent"] as? Bool else { return .unknown }
            // Spent on Bitcoin → replaying our spend there would be a double-spend and get rejected,
            // so the coins are already effectively separated.
            return spent ? .chainSpecific : .shared
        } catch {
            return .unknown   // offline, timeout, TLS failure — all "we don't know", never "safe"
        }
    }

    /// Classify a whole set of outpoints, bounded-concurrently.
    ///
    /// The cap is deliberate: a wallet recovering an airdrop can hold hundreds of UTXOs, and firing
    /// them all at once at a public Esplora is how you get rate-limited into a wall of `.unknown`
    /// that looks exactly like "everything is fine".
    func statuses(for utxos: [Utxo], maxConcurrent: Int = 6) async -> [String: SplitCoinStatus] {
        var results: [String: SplitCoinStatus] = [:]
        var index = 0
        while index < utxos.count {
            let slice = utxos[index..<min(index + maxConcurrent, utxos.count)]
            await withTaskGroup(of: (String, SplitCoinStatus).self) { group in
                for utxo in slice {
                    group.addTask {
                        ("\(utxo.txid):\(utxo.vout)", await status(txid: utxo.txid, vout: utxo.vout))
                    }
                }
                for await (key, status) in group { results[key] = status }
            }
            index += maxConcurrent
        }
        return results
    }
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
