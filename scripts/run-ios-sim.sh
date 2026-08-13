#!/usr/bin/env bash
# Build, install, and launch the iOS app on the BOOTED simulator from the command line, skipping the
# Android build leg (SKIP_ACTION=none). Use this instead of `skip app launch --ios` when the Android
# gradle/skip-android-bridge leg is failing or no emulator is up — `swift build` + `skip export`
# already verify the Android side separately.
#
# Forwards the CoinNews DEV endpoint to the app via SIMCTL_CHILD_* (so the sim pulls from a local
# BitWindow) when its auth cookie is present. Override COINNEWS_DEV_ENDPOINT/NETWORK in the env.
#
# Usage:  scripts/run-ios-sim.sh [Debug|Release]   (default: Debug)
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="ECashWalletMobile App"
CONFIG="${1:-Debug}"
# Bundle id comes from Skip.env (the single source of truth) — hardcoding it here meant the
# 2026-08 rebrand installed the new app and then tried to launch the old identifier.
BUNDLE_ID="$(sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*//p' Skip.env | tr -d '[:space:]')"
DERIVED=".build/Darwin/DerivedData"

SIM_ID="$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
if [ -z "${SIM_ID:-}" ]; then
  echo "No booted simulator. Open one in Simulator.app (or 'xcrun simctl boot <udid>')." >&2
  exit 1
fi
echo "▸ Simulator: $SIM_ID   Config: $CONFIG"

# CoinNews source: by default the app uses the public coinnews.v1 indexer (CoinNewsEndpointRegistry).
# To test against a LOCAL BitWindow instead, opt in: COINNEWS_DEV_ENDPOINT=http://127.0.0.1:30301
# scripts/run-ios-sim.sh — its .auth.cookie is forwarded automatically.
if [ -n "${COINNEWS_DEV_ENDPOINT:-}" ]; then
  export SIMCTL_CHILD_COINNEWS_DEV_ENDPOINT="$COINNEWS_DEV_ENDPOINT"
  export SIMCTL_CHILD_COINNEWS_DEV_NETWORK="${COINNEWS_DEV_NETWORK:-signet}"
  COOKIE="$HOME/Library/Application Support/bitwindow/.auth.cookie"
  [ -f "$COOKIE" ] && export SIMCTL_CHILD_COINNEWS_DEV_TOKEN="$(tr -d '\r\n' < "$COOKIE")"
  echo "▸ CoinNews DEV override: $SIMCTL_CHILD_COINNEWS_DEV_ENDPOINT (network $SIMCTL_CHILD_COINNEWS_DEV_NETWORK)"
else
  echo "▸ CoinNews: public indexer (set COINNEWS_DEV_ENDPOINT to use a local BitWindow)"
fi

echo "▸ Building (Android leg disabled via SKIP_ACTION=none)…"
xcodebuild \
  -project Darwin/ECashWalletMobile.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "id=$SIM_ID" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  SKIP_ACTION=none \
  build

APP="$(find "$DERIVED/Build/Products/$CONFIG-iphonesimulator" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "${APP:-}" ]; then echo "Build produced no .app under $CONFIG-iphonesimulator" >&2; exit 1; fi

echo "▸ Installing $APP …"
xcrun simctl install "$SIM_ID" "$APP"

echo "▸ Launching $BUNDLE_ID …"
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID"
echo "✓ Done."
