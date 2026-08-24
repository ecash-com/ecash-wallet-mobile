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

    /// **Existence and spentness are two separate questions, and only one endpoint answers each.**
    ///
    /// `/tx/{txid}/outspend/{vout}` does NOT validate that the transaction exists — it answers from
    /// the spend index and returns `200 {"spent":false}` for a txid Bitcoin has never seen. Treating
    /// that as "unspent, therefore shared" marks every eCash-only coin as needing a split, forever,
    /// including the fresh output a split just created. (Verified against
    /// esplora.mainnet.drivechain.info.)
    ///
    /// `/tx/{txid}` is the existence test: 404 for unknown, 200 for known. It's also the cheap path —
    /// an eCash-only coin resolves in one request and never needs the second.
    private func txURL(txid: String) -> URL? {
        URL(string: "\(esploraBaseURL.trimmedTrailingSlash)/tx/\(txid)")
    }

    private func outspendURL(txid: String, vout: Int32) -> URL? {
        URL(string: "\(esploraBaseURL.trimmedTrailingSlash)/tx/\(txid)/outspend/\(vout)")
    }

    /// The decision itself, separated from the I/O so the logic that got this wrong is unit-tested.
    /// `spent` is nil when the outspend call didn't yield a usable answer.
    static func verdict(txExistsOnBitcoin: Bool, spent: Bool?) -> SplitCoinStatus {
        guard txExistsOnBitcoin else { return .chainSpecific }   // Bitcoin never had it → can't replay
        guard let spent else { return .unknown }                 // known there, but we couldn't tell
        // Spent on Bitcoin → replaying our spend would be a double-spend → already separated.
        return spent ? .chainSpecific : .shared
    }

    /// Classify one outpoint. Never throws — an unreachable backend yields `.unknown`, because
    /// "we couldn't check" and "it's safe" must never be the same answer on a money screen.
    func status(txid: String, vout: Int32) async -> SplitCoinStatus {
        guard let txURL = txURL(txid: txid) else { return .unknown }
        do {
            // 1. Does Bitcoin know this transaction at all?
            var request = URLRequest(url: txURL)
            request.timeoutInterval = 15
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            if http.statusCode == 404 { return Self.verdict(txExistsOnBitcoin: false, spent: nil) }
            guard http.statusCode == 200 else { return .unknown }

            // 2. It does — so the coin exists on both chains unless Bitcoin already spent it.
            guard let outspendURL = outspendURL(txid: txid, vout: vout) else { return .unknown }
            var spendRequest = URLRequest(url: outspendURL)
            spendRequest.timeoutInterval = 15
            let (data, spendResponse) = try await session.data(for: spendRequest)
            guard let spendHTTP = spendResponse as? HTTPURLResponse, spendHTTP.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let spent = json["spent"] as? Bool
            else { return Self.verdict(txExistsOnBitcoin: true, spent: nil) }
            return Self.verdict(txExistsOnBitcoin: true, spent: spent)
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
