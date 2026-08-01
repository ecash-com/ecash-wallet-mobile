// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import WalletService

// Apple-only: these exercise real crypto (P256K) against the official BIP-340 vectors, and the
// Android secp lib (fr.acinq, JNI) doesn't load under Robolectric (§11 — never run real native
// crypto there). The Android crypto path is covered by `skip export` (compile) + on-device publish.
#if !SKIP

/// CoinNews crypto, checked against AUTHORITATIVE vectors:
///  • SHA-256 — NIST `"abc"` vector.
///  • Tagged hash / ItemID — values computed independently (Python) from the spec definitions.
///  • BIP-340 Schnorr — the official BIP-340 test vectors (key→pubkey, (key,aux,msg)→sig, verify).
///
/// SHA-256 / tagged-hash / ItemID run on BOTH platforms (Apple CryptoKit + Android MessageDigest —
/// the latter works under Robolectric), so they're true parity tests. The Schnorr vectors are
/// guarded `#if !SKIP` because the Android secp lib (fr.acinq, JNI .so) doesn't load on the
/// Robolectric host JVM; the Apple side runs the real P256K vectors, and the Android secp path is
/// covered by `skip export` (compile) + on-device publish verification.
final class CoinNewsCryptoTests: XCTestCase {

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func data(hex: String) -> Data {
        var bytes = [UInt8]()
        let chars = Array(hex.utf8)
        var i = 0
        while i < chars.count {
            let hi = nib(chars[i]); let lo = nib(chars[i + 1])
            bytes.append(UInt8(hi * 16 + lo)); i += 2
        }
        return Data(bytes)
    }
    private func nib(_ b: UInt8) -> Int {
        let v = Int(b)
        if v >= 48 && v <= 57 { return v - 48 }
        if v >= 97 && v <= 102 { return v - 87 }
        return v - 55   // A–F
    }

    // MARK: - SHA-256 / tagged hash / ItemID (parity — both platforms)

    func testSHA256NISTVector() {
        XCTAssertEqual(hex(CoinNewsCrypto.sha256(Data(Array("abc".utf8)))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTaggedHashVote() {
        // taggedHash("CoinNews/Vote", 0x04 ‖ 12×0xAB) — independently computed.
        var msg = Data([0x04])
        msg.append(Data([UInt8](repeating: 0xAB, count: 12)))
        XCTAssertEqual(hex(CoinNewsCrypto.taggedHash("CoinNews/Vote", msg)),
                       "b9e3d142b83ad11542d4cd48c2f993609994d76e6c1a4946bd54ebc4d22116c4")
    }

    func testItemID() {
        // sha256(txid_LE ‖ vout_LE)[0:12] for display txid = 32×0x11, vout = 2.
        let id = CoinNewsCrypto.itemId(txidHex: String(repeating: "11", count: 32), vout: 2)
        XCTAssertEqual(id.map { hex($0) }, "1791740e40134f4c08b784c9")
    }

    func testItemIDRejectsBadTxid() {
        XCTAssertNil(CoinNewsCrypto.itemId(txidHex: "1234", vout: 0))   // not 32 bytes
    }

    // MARK: - BIP-340 Schnorr official vectors (Apple/P256K)

    func testBIP340Vectors() throws {
        #if !SKIP
        // (secretKey, publicKey, auxRand, message, signature) from the BIP-340 test vectors.
        let vectors: [(String, String, String, String, String)] = [
            ("0000000000000000000000000000000000000000000000000000000000000003",
             "F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9",
             "0000000000000000000000000000000000000000000000000000000000000000",
             "0000000000000000000000000000000000000000000000000000000000000000",
             "E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"),
            ("B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF",
             "DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659",
             "0000000000000000000000000000000000000000000000000000000000000001",
             "243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89",
             "6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A"),
        ]
        for (skHex, pkHex, auxHex, msgHex, sigHex) in vectors {
            let sk = data(hex: skHex)
            // 1. key → x-only pubkey.
            XCTAssertEqual(hex(try CoinNewsCrypto.xonlyPublicKey(privateKey: sk)).uppercased(), pkHex)
            // 2. (key, aux, msg) → exact BIP-340 signature.
            let sig = try CoinNewsCrypto.schnorrSign(message32: data(hex: msgHex), privateKey: sk, auxRand: data(hex: auxHex))
            XCTAssertEqual(hex(sig).uppercased(), sigHex)
            // 3. verify accepts the real sig, rejects a tampered one.
            XCTAssertTrue(CoinNewsCrypto.schnorrVerify(signature: sig, message32: data(hex: msgHex), xonlyPublicKey: data(hex: pkHex)))
            var bad = [UInt8](sig); bad[0] = bad[0] ^ 0x01
            XCTAssertFalse(CoinNewsCrypto.schnorrVerify(signature: Data(bad), message32: data(hex: msgHex), xonlyPublicKey: data(hex: pkHex)))
        }
        #endif
    }

    func testSchnorrSignVerifyRoundTrip() throws {
        #if !SKIP
        let sk = data(hex: "C90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9")
        let pk = try CoinNewsCrypto.xonlyPublicKey(privateKey: sk)
        let msg = CoinNewsCrypto.taggedHash("CoinNews/Vote", Data([0x04] + [UInt8](repeating: 0x11, count: 12)))
        let aux = Data([UInt8](repeating: 0x42, count: 32))
        let sig = try CoinNewsCrypto.schnorrSign(message32: msg, privateKey: sk, auxRand: aux)
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(CoinNewsCrypto.schnorrVerify(signature: sig, message32: msg, xonlyPublicKey: pk))
        // Wrong message → reject.
        let other = CoinNewsCrypto.taggedHash("CoinNews/Vote", Data([0x05] + [UInt8](repeating: 0x11, count: 12)))
        XCTAssertFalse(CoinNewsCrypto.schnorrVerify(signature: sig, message32: other, xonlyPublicKey: pk))
        #endif
    }
    // MARK: - Secure aux randomness

    /// BIP-340 aux randomness must come from the platform CSPRNG, not a general-purpose PRNG.
    /// Regression guard for the all-zero `zeroAux` this replaced (flagged in the Aug 2026 security
    /// assessment): zero aux is spec-valid, and there was never a nonce-reuse risk, but it forfeits
    /// fault/side-channel defence in depth.
    ///
    /// NOTE: like the rest of this file these run on APPLE only, so they cover `SecRandomCopyBytes`.
    /// The Android `java.security.SecureRandom` branch is verified by transpilation + a device run.
    func testSecureAuxRandIsCorrectLengthAndNotZero() throws {
        let aux = try CoinNewsCrypto.secureAuxRand()
        XCTAssertEqual(aux.count, 32)
        XCTAssertFalse(aux.allSatisfy { $0 == UInt8(0) }, "aux randomness must not be all zeros")
    }

    /// Two draws must differ — a per-call-seeded PRNG (the failure mode if Swift's random APIs were
    /// used and transpiled to kotlin.random.Random) would show up here.
    func testSecureAuxRandDiffersBetweenCalls() throws {
        XCTAssertNotEqual(try CoinNewsCrypto.secureAuxRand(), try CoinNewsCrypto.secureAuxRand())
    }

    /// Fresh aux must not break signing: signatures now differ per call (that's the point), so this
    /// asserts they still VERIFY rather than that they're equal.
    func testSigningWithSecureAuxStillVerifies() throws {
        let sk = Data([UInt8](repeating: UInt8(7), count: 32))
        let msg = Data([UInt8](repeating: UInt8(3), count: 32))
        let pk = try CoinNewsCrypto.xonlyPublicKey(privateKey: sk)
        let sig1 = try CoinNewsCrypto.schnorrSign(message32: msg, privateKey: sk,
                                                  auxRand: try CoinNewsCrypto.secureAuxRand())
        let sig2 = try CoinNewsCrypto.schnorrSign(message32: msg, privateKey: sk,
                                                  auxRand: try CoinNewsCrypto.secureAuxRand())
        XCTAssertTrue(CoinNewsCrypto.schnorrVerify(signature: sig1, message32: msg, xonlyPublicKey: pk))
        XCTAssertTrue(CoinNewsCrypto.schnorrVerify(signature: sig2, message32: msg, xonlyPublicKey: pk))
        XCTAssertNotEqual(sig1, sig2, "fresh aux randomness should produce distinct signatures")
    }

}
#endif  // !SKIP
