// swift-tools-version: 6.1

import PackageDescription

// ristretto255 group + scalar arithmetic for the Thunder-family sidechains (thunder-rust >= 0.18 signs
// with FROST(ristretto255, SHA-512)). swift-crypto has no ristretto255, and the official Swift libsodium
// wrapper ships an Apple-only binary, so this package vendors the handful of libsodium C files needed
// (see README.md) and compiles them from source for every platform — iOS, macOS, and Android via Skip Fuse.
let package = Package(
    name: "Ristretto255",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Ristretto255", targets: ["Ristretto255"]),
    ],
    targets: [
        .target(
            name: "CSodiumRistretto",
            cSettings: [
                .headerSearchPath("include/sodium"),
                // Stand-ins for libsodium's autoconf output; HAVE_TI_MODE is decided per-arch in
                // include/sodium/private/csodium_config.h.
                .define("CONFIGURED", to: "1"),
                .define("NATIVE_LITTLE_ENDIAN", to: "1"),
            ]
        ),
        .target(name: "Ristretto255", dependencies: ["CSodiumRistretto"]),
        .testTarget(name: "Ristretto255Tests", dependencies: ["Ristretto255"]),
    ]
)
