// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if os(WASI)
let dependencies: [Package.Dependency] = []
let packageDependencies: [Target.Dependency] = []
#else
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
]
let packageDependencies: [Target.Dependency] = [
    "blake3-c",
    .product(name: "Crypto", package: "swift-crypto")
]
#endif

let package = Package(
    name: "SwiftBlake3",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .macCatalyst(.v13),
        .watchOS(.v6),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "Blake3",
            targets: ["Blake3"]
        ),
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "blake3-c",
            cSettings: [
                .headerSearchPath("./lib/blake3/include"),
                // Force the PORTABLE C path — no SIMD. VENDORED FIX (eCash wallet): upstream
                // SwiftBlake3's `blake3_neon.c` gates on `__ARM_NEON__` (a legacy macro Android's
                // aarch64 clang doesn't define), while `blake3_dispatch.c` calls
                // `blake3_hash_many_neon` under `BLAKE3_USE_NEON == 1` — so on Android the symbol is
                // referenced but never compiled → `dlopen: cannot locate symbol blake3_hash_many_neon`
                // → the whole Swift .so fails to load and the app crashes at launch. Portable C
                // compiles + loads on every arch; the perf cost is irrelevant for hashing 32-byte
                // pubkeys / small txs. Forcing portable on ALL arches keeps x86 emulators safe too.
                .define("BLAKE3_USE_NEON", to: "0"),
                .define("BLAKE3_NO_SSE2"),
                .define("BLAKE3_NO_SSE41"),
                .define("BLAKE3_NO_AVX2"),
                .define("BLAKE3_NO_AVX512"),
            ]
        ),
        .target(
            name: "Blake3",
            dependencies: packageDependencies
        ),
    ]
)
