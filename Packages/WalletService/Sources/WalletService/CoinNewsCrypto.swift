// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(CryptoKit)
import CryptoKit            // SHA-256 (Apple). `canImport` (not `!SKIP`) so the native-Android pass,
#endif                      // where SKIP is undefined but CryptoKit is absent, doesn't try to import.
#if canImport(P256K)
import P256K                // BIP-340 Schnorr (Apple) — Android uses fr.acinq.secp256k1 via #if SKIP
#endif
#if canImport(Security)
import Security             // SecRandomCopyBytes (Apple CSPRNG) — Android uses java.security.SecureRandom
#endif

#if !SKIP_BRIDGE
/// CoinNews cryptographic primitives — SHA-256, BIP-340 tagged hashes, ItemID, and BIP-340 Schnorr
/// (x-only pubkey + sign/verify). Lives in the BDK seam alongside key handling. NEVER hand-rolled:
/// SHA-256 = CryptoKit (iOS) / `java.security.MessageDigest` (Android); Schnorr = swift-secp256k1
/// `P256K` (iOS) / `fr.acinq.secp256k1` (Android) — both wrap audited libsecp256k1 (Golden Rule §1).
///
/// `public` (+ `@nobridge`) so sibling files in the transpiled module resolve it in Kotlin; not part
/// of the bridged surface.
public enum CoinNewsCrypto {

    // MARK: - SHA-256

    public static func sha256(_ data: Data) -> Data {
        #if !SKIP
        return Data(SHA256.hash(data: data))
        #else
        let md = java.security.MessageDigest.getInstance("SHA-256")
        return Data(platformValue: md.digest(data.platformValue))
        #endif
    }

    /// BIP-340 tagged hash: `sha256(sha256(tag) ‖ sha256(tag) ‖ msg)`.
    public static func taggedHash(_ tag: String, _ msg: Data) -> Data {
        let tagHash = sha256(Data(Array(tag.utf8)))
        var preimage = Data()
        preimage.append(tagHash)
        preimage.append(tagHash)
        preimage.append(msg)
        return sha256(preimage)
    }

    /// ItemID (spec §4): `sha256(txid_LE(32) ‖ vout_LE(4))[0:12]`. `txidHex` is the DISPLAY txid
    /// (big-endian); `txid_LE` is its byte-reversal. Returns nil if the txid isn't 32 bytes of hex.
    public static func itemId(txidHex: String, vout: UInt32) -> Data? {
        guard let txidBE = bytesFromHex(txidHex), txidBE.count == 32 else { return nil }
        var bytes = [UInt8](txidBE.reversed())                 // txid_LE
        let v = Int64(vout)                                    // Int64 (Kotlin Long): UInt32 bit-ops don't transpile, and 32-bit Int overflows
        bytes.append(UInt8(v & 0xFF))                          // vout_LE (4 bytes)
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
        let digest = sha256(Data(bytes))
        var out = [UInt8]()
        for i in 0..<12 { out.append(digest[i]) }   // first 12 bytes (avoid Array(slice) — won't infer in Kotlin)
        return Data(out)
    }

    // MARK: - BIP-340 Schnorr

    /// 32-byte BIP-340 x-only public key for a 32-byte private key.
    public static func xonlyPublicKey(privateKey: Data) throws -> Data {
        #if !SKIP
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        return Data(key.xonly.bytes)
        #else
        // acinq pubkeyCreate → 65-byte uncompressed (0x04 ‖ X(32) ‖ Y(32)); x-only = the X coord.
        let pub = fr.acinq.secp256k1.Secp256k1.pubkeyCreate(privateKey.platformValue)
        return Data(platformValue: pub.copyOfRange(1, 33))
        #endif
    }

    /// 32 fresh bytes of BIP-340 auxiliary randomness, from the platform CSPRNG.
    ///
    /// **Do not replace this with Swift's `SystemRandomNumberGenerator` / `random(in:)`.** This module
    /// is transpiled, so those become Kotlin's `kotlin.random.Random` on Android — a general-purpose
    /// PRNG, **not** cryptographically secure. The code would look right and silently be weaker than
    /// what it replaced, which is the worst possible outcome for nonce randomness. Hence the explicit
    /// split: `SecRandomCopyBytes` on Apple, `java.security.SecureRandom` on Android.
    ///
    /// Why it matters: aux randomness is BIP-340's defence-in-depth against fault and side-channel
    /// attacks on nonce derivation. All-zero aux is *valid* per the spec (and the signature is still
    /// deterministic-per-message, so there's no nonce-reuse risk), but it forfeits that protection.
    public static func secureAuxRand() throws -> Data {
        #if !SKIP
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw WalletError.signingFailed }
        return Data(bytes)
        #else
        let bytes = kotlin.ByteArray(32)
        java.security.SecureRandom().nextBytes(bytes)
        return Data(platformValue: bytes)
        #endif
    }

    /// BIP-340 Schnorr signature (64 B) over a 32-byte message. `auxRand` must be 32 bytes (BIP-340
    /// nonce randomness — pass `secureAuxRand()` in production; fixed bytes for test vectors).
    public static func schnorrSign(message32: Data, privateKey: Data, auxRand: Data) throws -> Data {
        #if !SKIP
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        var message = [UInt8](message32)
        var aux = [UInt8](auxRand)
        let signature = try aux.withUnsafeMutableBytes { (auxPtr: UnsafeMutableRawBufferPointer) in
            try key.signature(message: &message, auxiliaryRand: auxPtr.baseAddress, strict: true)
        }
        return signature.dataRepresentation
        #else
        let sig = fr.acinq.secp256k1.Secp256k1.signSchnorr(message32.platformValue, privateKey.platformValue, auxRand.platformValue)
        return Data(platformValue: sig)
        #endif
    }

    /// Verify a 64-byte BIP-340 signature over a 32-byte message against a 32-byte x-only pubkey.
    public static func schnorrVerify(signature: Data, message32: Data, xonlyPublicKey: Data) -> Bool {
        #if !SKIP
        guard let sig = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else { return false }
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: [UInt8](xonlyPublicKey))
        var message = [UInt8](message32)
        return xonly.isValid(sig, for: &message)
        #else
        return fr.acinq.secp256k1.Secp256k1.verifySchnorr(signature.platformValue, message32.platformValue, xonlyPublicKey.platformValue)
        #endif
    }

    // MARK: - Hex (transpile-safe: UTF-8 bytes + Int comparisons, no Character switch)

    static func bytesFromHex(_ hex: String) -> [UInt8]? {
        let ascii = Array(hex.utf8)
        guard ascii.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        var i = 0
        while i < ascii.count {
            guard let hi = nibble(ascii[i]), let lo = nibble(ascii[i + 1]) else { return nil }
            out.append(UInt8(hi * 16 + lo))
            i += 2
        }
        return out
    }

    private static func nibble(_ b: UInt8) -> Int? {
        let v = Int(b)
        if v >= 48 && v <= 57 { return v - 48 }
        if v >= 97 && v <= 102 { return v - 87 }
        if v >= 65 && v <= 70 { return v - 55 }
        return nil
    }
}
#endif // !SKIP_BRIDGE
