# Ristretto255

ristretto255 group and scalar arithmetic for the wallet's Thunder-family sidechain support. thunder-rust
0.18+ (and truthcoin-dc / coinshift-rs) sign with FROST(ristretto255, SHA-512), which neither CryptoKit
nor swift-crypto provides. The official Swift libsodium wrapper ships an Apple-only binary, so this
package vendors the few libsodium C files needed and compiles them from source on every platform
(iOS, macOS, Android via Skip Fuse).

## Vendored from libsodium 1.0.22-RELEASE (ISC licence, see `LICENSE`)

Under `Sources/CSodiumRistretto/`:

- `libsodium/crypto_core/ed25519/core_ristretto255.c`, `core_ed25519.c`
- `libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c` + `fe_51/`, `fe_25_5/` headers
- `libsodium/crypto_scalarmult/ristretto255/ref10/scalarmult_ristretto255_ref10.c`
- `libsodium/sodium/utils.c`
- `include/sodium/` — libsodium's public and private headers, unmodified except as noted below

## Local changes (everything else is byte-identical to upstream)

- `include/sodium/private/csodium_config.h` (new) replaces autoconf: enables `HAVE_TI_MODE` (64-bit
  field arithmetic) only where the compiler has `__int128`, so 32-bit Android ABIs use the portable path.
  `private/common.h` and `private/ed25519_ref10.h` each gained one `#include` of it.
- `shim/sodium_shim.c` (new) provides `sodium_misuse` and `randombytes_buf` (OS CSPRNG) instead of
  `sodium/core.c` + `randombytes/`, which would pull in the rest of libsodium.
- `include/csodium_ristretto.h` + `include/module.modulemap` (new) expose only the ristretto255 headers.
- `Package.swift` defines `CONFIGURED` and `NATIVE_LITTLE_ENDIAN`.

## Updating

Copy the files above from a new libsodium release, re-apply the local changes, then run
`swift test --package-path Packages/Ristretto255` (RFC 9496 vectors) **and launch the app on a real
Android device or emulator**. A C dependency that builds can still fail to load on Android (BLAKE3 did —
see `Packages/SwiftBlake3`), so a successful `skip export` is not enough.
