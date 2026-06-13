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
        // The BDK seam lives in its own transpiled+bridged package (the SkipSQL pattern);
        // it carries the bdk-swift / bdk-android dependencies internally.
        .package(path: "Packages/WalletService")
    ],
    targets: [
        .target(name: "ECashWalletMobile", dependencies: [
            .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
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
