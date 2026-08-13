#!/usr/bin/env bash
# Build, install, and launch the iOS app on a connected physical iPhone from the command line.
# `skip app launch` only targets the booted simulator, so the device path is xcodebuild (build +
# sign) → xcrun devicectl (install + launch). Requires device profiles set up in Xcode once.
#
# Usage:  scripts/run-ios-device.sh [Debug|Release]   (default: Debug)
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="ECashWalletMobile App"
CONFIG="${1:-Debug}"
# Bundle id comes from Skip.env (the single source of truth) — hardcoding it here meant the
# 2026-08 rebrand installed the new app and then tried to launch the old identifier.
BUNDLE_ID="$(sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*//p' Skip.env | tr -d '[:space:]')"
# Reuse Skip's DerivedData so this shares compiled artifacts with `skip app launch` (faster).
DERIVED=".build/Darwin/DerivedData"

# First known physical device (UUID-shaped identifier on any non-header row), with its state.
DEVICE_LINE="$(xcrun devicectl list devices 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-/){print; exit}}')"
DEVICE_ID="$(printf '%s\n' "$DEVICE_LINE" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
if [ -z "${DEVICE_ID:-}" ]; then
  echo "No paired iPhone found. Plug it in, unlock it, and 'Trust' this Mac." >&2
  exit 1
fi
echo "▸ Device: $DEVICE_ID   Config: $CONFIG"
echo "▸ State : $(printf '%s\n' "$DEVICE_LINE" | sed -E 's/.*[0-9a-fA-F-]{36}[[:space:]]+//')"
echo "  (if not 'connected', plug in + unlock the phone so install/launch can reach it)"

echo "▸ Building (Android leg disabled via SKIP_ACTION=none)…"
xcodebuild \
  -project Darwin/ECashWalletMobile.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -skipPackagePluginValidation \
  SKIP_ACTION=none \
  build

APP="$(find "$DERIVED/Build/Products/$CONFIG-iphoneos" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "${APP:-}" ]; then echo "Build produced no .app under $CONFIG-iphoneos" >&2; exit 1; fi

echo "▸ Installing $APP …"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo "▸ Launching $BUNDLE_ID …"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
echo "✓ Done."
