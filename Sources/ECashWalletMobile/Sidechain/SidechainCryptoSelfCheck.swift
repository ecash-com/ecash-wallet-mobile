// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// TEMPORARY (Thunder key port, docs/thunder-key-port.md): a launch-time check that the vendored
/// libsodium LOADS and computes correctly on the device at hand — a C dependency that builds can still
/// fail to load on Android (BLAKE3 did). Logged once from `onInit`. Remove at the port's cleanup step.
enum SidechainCryptoSelfCheck {
    static func run() -> String {
        do {
            let scheme = RistrettoSidechainKeyScheme.thunder
            let seed = Bip39Seed.seed(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
            let secret = try scheme.signingKey(seed: seed, index: 0)
            let account = try scheme.accountPublicKey(seed: seed)
            let publicKey = try scheme.publicKey(account: account, index: 0)
            let address = SidechainAddress(publicKey: publicKey).base58
            let message = Array("thunder".utf8)
            let signature = try FrostSchnorr.sign(message: message, secret: secret)
            let verified = FrostSchnorr.verify(signature: signature, publicKey: publicKey, message: message)
            let ok = address == "NKqSr4bQejFbKpd5yLQgWEiMJFx" && verified
            return "SidechainCryptoSelfCheck \(ok ? "OK" : "FAILED") address=\(address) signVerify=\(verified)"
        } catch {
            return "SidechainCryptoSelfCheck FAILED error=\(error)"
        }
    }
}
