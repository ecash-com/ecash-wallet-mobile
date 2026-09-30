#!/usr/bin/env bash
# Download the Satoshi typeface from Fontshare into both font locations (iOS module resources +
# Android res/font). Idempotent: does nothing when the files are already present.
#
# Why the files aren't committed: Satoshi ships under the ITF Free Font License, which ALLOWS
# embedding the font in our app binaries but FORBIDS redistributing the font files through a public
# repository (FFL §02). This repo is public, so the .ttfs are gitignored and fetched at build time
# instead. Every build entry point (run-*.sh, build-apk.sh, fastlane, CI) calls this script.
#
# Usage:  scripts/fetch-fonts.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_DIR="Sources/ECashWalletMobile/Resources/Fonts"
ANDROID_DIR="Android/app/src/main/res/font"
WEIGHTS=(Regular Medium Bold)

missing=0
for w in "${WEIGHTS[@]}"; do
  lower="satoshi_$(echo "$w" | tr '[:upper:]' '[:lower:]').ttf"
  [ -f "$IOS_DIR/$lower" ] && [ -f "$ANDROID_DIR/$lower" ] || missing=1
done
[ "$missing" = 0 ] && exit 0

echo "▸ Fetching Satoshi from Fontshare …"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/satoshi.zip" "https://api.fontshare.com/v2/fonts/download/satoshi"
unzip -q "$TMP/satoshi.zip" -d "$TMP"

for w in "${WEIGHTS[@]}"; do
  src="$(find "$TMP" -path "*/WEB/fonts/Satoshi-$w.ttf" | head -1)"
  if [ -z "$src" ]; then
    echo "Satoshi-$w.ttf not found in the Fontshare download (did the archive layout change?)" >&2
    exit 1
  fi
  # Lowercase snake_case file names: Android resource names must be, and SkipUI resolves
  # Font.custom("Satoshi-Bold") to the resource `satoshi_bold`. The font data itself is untouched.
  lower="satoshi_$(echo "$w" | tr '[:upper:]' '[:lower:]').ttf"
  cp "$src" "$IOS_DIR/$lower"
  cp "$src" "$ANDROID_DIR/$lower"
done
echo "✓ Satoshi installed."
