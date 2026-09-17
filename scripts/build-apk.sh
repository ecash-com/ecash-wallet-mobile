#!/usr/bin/env bash
# Build a shareable RELEASE APK (does NOT install to a device) to pass around to testers.
#
# Output: .build/dist/eCashWallet-<version>-<arch>.apk  (copied from skip-export, versioned name).
# Signing: the release signingConfig falls back to the DEBUG keystore when there's no
# Android/keystore.properties, so the APK is sideload-installable (testers must allow "install
# unknown apps"). It is NOT Play-grade — set up an upload keystore (keystore.properties) for that.
#
# Arch: defaults to aarch64 (arm64-v8a) — covers ~all modern phones. USE THE DEFAULT for Play.
#
# ⚠️ DO NOT USE ARCH=all — it is SILENTLY BROKEN on Skip 1.9.2 (verified 2026-09-17). It finishes in
# ~115s instead of ~300s and emits a 27MB bundle containing 8 native libs and NO SWIFT RUNTIME (no
# libswiftCore.so). A Skip Fuse app without the Swift runtime crashes on launch — the native Swift IS
# the app. Exit code is 0, the bundle signs correctly and stamps the right versionCode, so nothing but
# the size gives it away. The guard at the end of this script now catches it either way.
# `ARCH=all` was never worth it regardless: the last known-good "all" build (0.2.2) contained only
# arm64-v8a, so it never actually produced multiple ABIs.
#
# Usage:  scripts/build-apk.sh              # arm64 release APK + AAB  ← use this
#         ARCH=x86_64 scripts/build-apk.sh  # Intel emulator only
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-aarch64}"
VERSION="$(grep -E '^MARKETING_VERSION' Skip.env | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
[ -n "$VERSION" ] || VERSION="0.0.0"

echo "▸ Building release APK  v$VERSION  (arch=$ARCH, no iOS)…"
skip export --release --no-ios --arch "$ARCH"

SRC=".build/skip-export/ECashWalletMobile-release.apk"
[ -f "$SRC" ] || { echo "APK not found at $SRC" >&2; exit 1; }

mkdir -p .build/dist
DEST=".build/dist/eCashWallet-${VERSION}-${ARCH}.apk"
cp "$SRC" "$DEST"
echo "✓ Shareable APK:"
ls -lh "$DEST"
echo "  (debug-key signed unless Android/keystore.properties exists — fine for sideloading)"

# Stage the AAB under a versioned name too. `skip export` leaves it at a fixed path with a generic
# name, so a stale bundle from an earlier version is indistinguishable from a fresh one at a glance —
# which is exactly how a 0.2.0 AAB nearly got uploaded as 0.2.1. Play wants THIS file, not the APK.
AAB_SRC=".build/Android/app/outputs/bundle/release/app-release.aab"
if [ -f "$AAB_SRC" ]; then
  AAB_DEST=".build/dist/eCashWallet-${VERSION}.aab"
  cp "$AAB_SRC" "$AAB_DEST"
  echo "✓ Play bundle (upload THIS to Google Play):"
  ls -lh "$AAB_DEST"
fi

# ---------------------------------------------------------------------------
# Swift-runtime guard.
#
# The failure this catches produces a VALID-LOOKING artifact: exit 0, correct versionCode, correctly
# signed, "✓ Play bundle" printed — but with the Swift runtime missing, so it crashes on launch. It
# cost us a near-miss upload on 2026-09-17 (ARCH=all). A healthy arm64 build carries ~42 .so files
# including libswiftCore.so; the broken one carried 8 and none of the Swift ones.
#
# Checked on the APK because an AAB stores libs in a different layout; the two are built from the
# same native output, so the APK passing means the AAB is sound.
# ---------------------------------------------------------------------------
# NB: count, don't use `grep -q`. Under `set -o pipefail`, grep -q exits on the first match, unzip
# gets SIGPIPE and returns non-zero, and pipefail reports the whole pipeline as failed — so the guard
# would abort BECAUSE it found the library. (Cost one good artifact on 2026-09-17.)
LIBS=$(unzip -l "$DEST" | grep -c '\.so$' || true)
SWIFT_LIBS=$(unzip -l "$DEST" | grep -c 'libswiftCore\.so' || true)
if [ "$SWIFT_LIBS" -eq 0 ]; then
  echo "" >&2
  echo "✗ ABORT: no libswiftCore.so in $DEST ($LIBS native libs)." >&2
  echo "  The Swift runtime is missing — this build would crash on launch." >&2
  echo "  Most likely cause: ARCH=all (broken on Skip 1.9.2). Rebuild with the default arch:" >&2
  echo "      rm -rf .build/Android .build/skip-export .build/plugins/outputs/ecash-wallet-mobile" >&2
  echo "      scripts/build-apk.sh" >&2
  rm -f "$DEST" "${AAB_DEST:-}"      # don't leave an uploadable-looking artifact behind
  exit 1
fi
echo "✓ Swift runtime present ($LIBS native libs, incl. libswiftCore.so)"
