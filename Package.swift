// swift-tools-version: 6.1
// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later
// This is a Skip (https://skip.dev) package.
import PackageDescription

let package = Package(
    name: "ecash-wallet-mobile",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "ECashWalletMobile", type: .dynamic, targets: ["ECashWalletMobile"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.2"),
        .package(url: "https://source.skip.tools/skip-fuse-ui.git", from: "1.0.0"),
        // Pure-Swift QR generator (no platform deps) — compiles natively for both iOS and Android
        // via Fuse, so the receive QR renders identically with no `#if`. (SkipQRCode is scan-only,
        // for the Send scanner later — it has no generation API.)
        .package(url: "https://github.com/fwcd/swift-qrcode-generator.git", from: "2.0.0"),
        // Camera-based QR/barcode SCANNER for the Send flow (scan-only; generation stays QRCodeGenerator).
        .package(url: "https://source.skip.tools/skip-qrcode.git", "0.0.1"..<"2.0.0"),
        // Cross-platform push via the real Firebase SDKs (FCM on both platforms incl. iOS-over-APNs).
        // Replaces skip-notify: we need topics + a single console broadcast to ALL devices, which the
        // token-only skip-notify couldn't do. Used for manual announcements (docs/notifications.md).
        .package(url: "https://github.com/skiptools/skip-firebase.git", "0.0.0"..<"2.0.0"),
        // Apple's open-source Crypto (the CryptoKit API; BoringSSL-backed off-Apple) — ed25519 via
        // Curve25519.Signing, for the future Thunder sidechain (ed25519 keys/sigs; docs/thunder-*).
        // Builds for both platforms under Fuse (verified). (Range capped <4.0.0 to match SwiftBlake3.)
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
        // BLAKE3 (official C impl wrapped in Swift) — Thunder hashes ed25519 pubkeys to addresses with
        // it. VENDORED (Packages/SwiftBlake3) rather than the upstream github package: upstream's
        // `blake3_neon.c` gates on `__ARM_NEON__` (undefined on Android aarch64 clang) while the
        // dispatcher calls `blake3_hash_many_neon` → undefined symbol → the Swift .so won't dlopen on
        // Android (app crashed at launch on the Saga). Our vendored copy forces the portable C path.
        .package(path: "Packages/SwiftBlake3"),
        // The BDK seam lives in its own transpiled+bridged package (the SkipSQL pattern);
        // it carries the bdk-swift / bdk-android dependencies internally.
        .package(path: "Packages/WalletService")
    ],
    targets: [
        .target(name: "ECashWalletMobile", dependencies: [
            .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
            .product(name: "SkipQRCode", package: "skip-qrcode"),
            .product(name: "SkipFirebaseCore", package: "skip-firebase"),
            .product(name: "SkipFirebaseMessaging", package: "skip-firebase"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Blake3", package: "SwiftBlake3"),
            .product(name: "WalletService", package: "WalletService")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        // View-model / pure-logic tests. XCTest so they run on the host (`SKIP_BRIDGE=1 swift test`)
        // and on Android via `skip android test` (CLI mode). These exercise the view-model state
        // machines through their injected seams — never real BDK / Keychain / network.
        .testTarget(name: "ECashWalletMobileTests", dependencies: [
            "ECashWalletMobile",
            .product(name: "WalletService", package: "WalletService"),
            .product(name: "SkipTest", package: "skip"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
