// swift-tools-version: 6.1
// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later
// The BDK seam, as a standalone Skip library package (the SkipSQL pattern).
//
// WalletService is a TRANSPILED (Skip Lite) library so its Kotlin output can
// `import org.bitcoindevkit.__` directly; the Fuse app consumes it as a bridged package.
// It lives in its own package — NOT a second target in the app — because a Fuse app is a
// single native module and transpiled code belongs in a separate package.
import PackageDescription

let package = Package(
    name: "WalletService",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WalletService", type: .dynamic, targets: ["WalletService"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.11"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
        // Secure storage (mnemonics) — iOS Keychain / Android Keystore.
        .package(url: "https://source.skip.tools/skip-keychain.git", "0.0.0"..<"2.0.0"),
        // NOTE: SkipSQL (local DB) is added back in M2 with the real SQLiteWalletStore.
        // BDK — Apple binary, linked only on Apple platforms. Android gets bdk-android
        // via Skip/skip.yml. Pinned to 2.3.x: stay pre-3.0.
        .package(url: "https://github.com/bitcoindevkit/bdk-swift.git", .upToNextMinor(from: "2.3.1")),
        // BIP-340 Schnorr for CoinNews authorship (iOS/macOS only — Android uses
        // fr.acinq.secp256k1 via Skip/skip.yml). Product `P256K`; `schnorrsig` is a default trait.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", .upToNextMinor(from: "0.23.2")),
    ],
    targets: [
        .target(name: "WalletService", dependencies: [
            .product(name: "SkipFoundation", package: "skip-foundation"),
            .product(name: "SkipKeychain", package: "skip-keychain"),
            .product(name: "BitcoinDevKit", package: "bdk-swift",
                     condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "P256K", package: "swift-secp256k1",
                     condition: .when(platforms: [.iOS, .macOS])),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),
        // Parity tests: XCTest on Apple, transpiled to JUnit + run via Robolectric on `swift test`.
        // Pure logic only here — never load real BDK under Robolectric.
        .testTarget(name: "WalletServiceTests", dependencies: [
            "WalletService",
            .product(name: "SkipTest", package: "skip"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
