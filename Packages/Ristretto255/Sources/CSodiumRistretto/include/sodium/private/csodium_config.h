/* VENDORED ADDITION (eCash.com Wallet) — replaces libsodium's autoconf-generated defines.
 * HAVE_TI_MODE selects the 64-bit (radix-2^51, __int128) field arithmetic. Enable it only where the
 * compiler actually has __int128 (arm64 / x86_64); 32-bit targets (armv7, i686 emulators) fall back
 * to libsodium's portable radix-2^25.5 path. CONFIGURED and NATIVE_LITTLE_ENDIAN come from
 * Package.swift (every target we build for is little-endian). */
#ifndef CSODIUM_CONFIG_H
#define CSODIUM_CONFIG_H
#if !defined(HAVE_TI_MODE) && defined(__SIZEOF_INT128__)
# define HAVE_TI_MODE 1
#endif
#endif
