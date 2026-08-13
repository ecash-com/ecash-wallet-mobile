#!/usr/bin/env bash
# Build a shareable RELEASE APK (does NOT install to a device) to pass around to testers.
#
# Output: .build/dist/eCashWallet-<version>-<arch>.apk  (copied from skip-export, versioned name).
# Signing: the release signingConfig falls back to the DEBUG keystore when there's no
# Android/keystore.properties, so the APK is sideload-installable (testers must allow "install
# unknown apps"). It is NOT Play-grade — set up an upload keystore (keystore.properties) for that.
#
# Arch: defaults to aarch64 (arm64-v8a) — covers ~all modern phones, smallest APK. Use ARCH=all for
# every ABI (much larger: bundles the Swift runtime per ABI), or ARCH=x86_64 for an Intel emulator.
#
# Usage:  scripts/build-apk.sh            # arm64 release APK
#         ARCH=all scripts/build-apk.sh   # every ABI (broadest device coverage)
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
