// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import Crypto
@testable import ECashWalletMobile

/// The Thunder key stack, each layer pinned to a *published* test vector so correctness doesn't
/// depend on our own implementation:
///   • Base58  → Bitcoin Core's `base58_encode_decode.json`
///   • BIP39   → the canonical "abandon…about" / "TREZOR" seed vector
///   • SLIP-0010 ed25519 → the spec's Test Vector 1 (satoshilabs/slips)
/// The composed Thunder address (BLAKE3∘derive) is then trusted-by-construction; its golden value is
/// pinned here and still wants a cross-check against a real thunder-rust wallet before we ship sends.
/// Swift Testing so it runs on host + Android APK mode.
@Suite struct ThunderKeyTests {

    // MARK: helpers

    private static func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    /// The SLIP-0010 "public key" field for an ed25519 node: `0x00 || ed25519_pubkey(node.key)`.
    private static func slip10Public(_ node: Slip10Ed25519.Node) -> [UInt8] {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: node.key)
        return [0x00] + Array(key.publicKey.rawRepresentation)
    }

    // MARK: - Base58 (Bitcoin Core vectors)

    @Test func base58EncodeMatchesVectors() {
        let vectors: [(String, String)] = [
            ("", ""),
            ("61", "2g"),
            ("626262", "a3gV"),
            ("636363", "aPEr"),
            ("73696d706c792061206c6f6e6720737472696e67", "2cFupjhnEsSn59qHXstmK2ffpLv2"),
            ("00eb15231dfceb60925886b67d065299925915aeb172c06647", "1NS17iag9jJgTHD1VXjvLCEnZuQ3rJDE9L"),
            ("516b6fcd0f", "ABnLTmg"),
            ("00000000000000000000", "1111111111"),  // leading-zero bytes → '1's
        ]
        for (hexIn, expected) in vectors {
            #expect(Base58.encode(Self.bytes(hexIn)) == expected, "encode \(hexIn)")
            #expect(Base58.decode(expected).map(Self.hex) == hexIn, "decode \(expected)")
        }
    }

    @Test func base58RejectsOutOfAlphabet() {
        #expect(Base58.decode("0OIl") == nil)   // 0, O, I, l are not in the base58 alphabet
    }

    // MARK: - BIP39 seed (canonical vector)

    @Test func bip39SeedMatchesVector() {
        let mnemonic = "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon about"
        let seed = Bip39Seed.seed(mnemonic: mnemonic, passphrase: "TREZOR")
        #expect(Self.hex(seed) == "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553"
            + "1f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
    }

    // MARK: - SLIP-0010 ed25519 (spec Test Vector 1, seed 000102…0f)

    private static let slip10Seed = bytes("000102030405060708090a0b0c0d0e0f")

    @Test func slip10MasterMatchesVector() {
        let m = Slip10Ed25519.master(seed: Self.slip10Seed)
        #expect(Self.hex(m.key) == "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7")
        #expect(Self.hex(m.chainCode) == "90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb")
        #expect(Self.hex(Self.slip10Public(m)) == "00a4b2856bfec510abab89753fac1ac0e1112364e7d250545963f135f2a33188ed")
    }

    @Test func slip10FirstHardenedChildMatchesVector() {
        let node = Slip10Ed25519.derive(seed: Self.slip10Seed, hardenedPath: [0])   // m/0'
        #expect(Self.hex(node.key) == "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3")
        #expect(Self.hex(node.chainCode) == "8b59aa11380b624e81507a27fedda59fea6d0b779a778918a2fd3590e16e9c69")
        #expect(Self.hex(Self.slip10Public(node)) == "008c8a13df77a28f3445213a0f432fde644acaa215fc72dcdf300d5efaa85d350c")
    }

    @Test func slip10DeepPathMatchesVector() {
        // m/0'/1'/2'/2'/1000000000'
        let node = Slip10Ed25519.derive(seed: Self.slip10Seed, hardenedPath: [0, 1, 2, 2, 1000000000])
        #expect(Self.hex(node.key) == "8f94d394a8e8fd6b1bc2f3f49f5c47e385281d5c17e65324b0f62483e37e8793")
        #expect(Self.hex(node.chainCode) == "68789923a0cac2cd5a29172a475fe9e0fb14cd6adb5ad98a3fa70333e7afa230")
        #expect(Self.hex(Self.slip10Public(node)) == "003c24da049451555d51a7014a37337aa4e12d41e485abccfa46b47dfb2af54b7a")
    }

    // MARK: - ThunderKey (composed derivation)

    private static let testMnemonic = "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    @Test func thunderAccountPathIsAllHardened100() {
        #expect(ThunderKey.accountPath == [1, 0, 0])   // m/1'/0'/0' (then /index'), per wallet.rs
    }

    @Test func thunderKeyShapeIsCorrect() throws {
        let key = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 0)
        #expect(key.publicKeyBytes.count == 32)   // ed25519 verifying key
        #expect(key.address.bytes.count == 20)    // BLAKE3(pubkey)[..20]
        #expect(!key.address.base58.isEmpty)
    }

    @Test func thunderKeyDerivationIsDeterministic() throws {
        let a = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 0)
        let b = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 0)
        #expect(a.address == b.address)
        #expect(a.publicKeyBytes == b.publicKeyBytes)
    }

    @Test func thunderKeyIndexChangesTheAddress() throws {
        let k0 = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 0)
        let k1 = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 1)
        #expect(k0.address != k1.address)
        #expect(k0.publicKeyBytes != k1.publicKeyBytes)
    }

    @Test func thunderAddressBase58RoundTrips() throws {
        let key = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 0)
        let parsed = ThunderAddress(base58: key.address.base58)
        #expect(parsed == key.address)
    }

    @Test func thunderKeySignatureVerifies() throws {
        let key = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 0)
        let message = Array("thunder tx body".utf8)
        let signature = try key.sign(message)
        #expect(signature.count == 64)   // ed25519
        let verifying = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKeyBytes)
        #expect(verifying.isValidSignature(Data(signature), for: Data(message)))
    }

    /// GOLDEN — pins the full pipeline (BIP39 → SLIP-0010 m/1'/0'/0'/0' → ed25519 pub → BLAKE3[..20]
    /// → base58) for the canonical "abandon…about" mnemonic. Primitives above are each vector-proven,
    /// so this locks the *composition*. TODO: cross-check this exact string against a real thunder-rust
    /// wallet (`docs/thunder-sidechain-support.md`) before enabling Thunder sends.
    @Test func thunderAddressGolden() throws {
        let key = try ThunderKey.derive(mnemonic: Self.testMnemonic, index: 0)
        #expect(key.address.base58 == "38VvRdmcQREr1UAcZma98WLFVpAp")
    }
}
