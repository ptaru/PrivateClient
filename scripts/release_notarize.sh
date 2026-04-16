#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="${SCHEME:-PrivateClient}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-CM6PR6R3U2}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-uk.tarun.PrivateClient}"
APPEX_BUNDLE_ID="${APPEX_BUNDLE_ID:-uk.tarun.PrivateClient.tunnel}"
PROFILE_SEARCH_DIR="${PROFILE_SEARCH_DIR:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"
DEV_ID_IDENTITY="${DEV_ID_IDENTITY:-Developer ID Application: Tarun Pemmaraju (CM6PR6R3U2)}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/PrivateClient.xcarchive}"
DIST_DIR="${DIST_DIR:-$BUILD_DIR/dist}"
APPLE_ID="${APPLE_ID:-}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:-}"

usage() {
  cat <<'EOF'
Usage:
  APPLE_ID="name@example.com" APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" ./scripts/release_notarize.sh

Optional environment variables:
  TEAM_ID
  DEV_ID_IDENTITY
  APP_BUNDLE_ID
  APPEX_BUNDLE_ID
  PROFILE_SEARCH_DIR
  BUILD_DIR
  ARCHIVE_PATH
  DIST_DIR
  SCHEME
  CONFIGURATION
EOF
}

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: $name" >&2
    usage >&2
    exit 1
  fi
}

find_direct_profile() {
  local expected_app_id="$1"
  local profile app_id all_devices

  shopt -s nullglob
  for profile in "$PROFILE_SEARCH_DIR"/*.provisionprofile; do
    security cms -D -i "$profile" >"$TMP_PROFILE_PLIST" 2>/dev/null || continue
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$TMP_PROFILE_PLIST" 2>/dev/null || true)"
    all_devices="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$TMP_PROFILE_PLIST" 2>/dev/null || true)"
    if [ "$app_id" = "$expected_app_id" ] && [ "$all_devices" = "true" ]; then
      printf '%s\n' "$profile"
      return 0
    fi
  done

  echo "Could not find a direct distribution provisioning profile for $expected_app_id" >&2
  exit 1
}

sign_frameworks_in() {
  local bundle_root="$1"
  local framework

  if [ ! -d "$bundle_root/Contents/Frameworks" ]; then
    return 0
  fi

  while IFS= read -r -d '' framework; do
    codesign --force --timestamp --options runtime --sign "$DEV_ID_IDENTITY" "$framework"
  done < <(find "$bundle_root/Contents/Frameworks" -mindepth 1 -maxdepth 1 -name '*.framework' -print0)
}

require_var APPLE_ID
require_var APP_SPECIFIC_PASSWORD

TMP_PROFILE_PLIST="$(mktemp -t privateclient-profile.XXXXXX)"
trap 'rm -f "$TMP_PROFILE_PLIST"' EXIT

APP_PROFILE_PATH="$(find_direct_profile "$TEAM_ID.$APP_BUNDLE_ID")"
APPEX_PROFILE_PATH="$(find_direct_profile "$TEAM_ID.$APPEX_BUNDLE_ID")"

APP_SRC="$ARCHIVE_PATH/Products/Applications/PrivateClient.app"
APP_DST="$DIST_DIR/PrivateClient.app"
APPEX_PATH="$APP_DST/Contents/PlugIns/PrivateClientTunnel.appex"
ZIP_PATH="$DIST_DIR/PrivateClient-Release.zip"
FINAL_ZIP="$DIST_DIR/PrivateClient-Release-notarized.zip"
APP_ENTITLEMENTS="$DIST_DIR/PrivateClient.entitlements.plist"
APPEX_ENTITLEMENTS="$DIST_DIR/PrivateClientTunnel.entitlements.plist"
NOTARY_JSON="$DIST_DIR/notary-submit.json"

rm -rf "$ARCHIVE_PATH" "$APP_DST" "$ZIP_PATH" "$FINAL_ZIP"
mkdir -p "$DIST_DIR"

xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive

/usr/bin/ditto "$APP_SRC" "$APP_DST"
cp "$APP_PROFILE_PATH" "$APP_DST/Contents/embedded.provisionprofile"
cp "$APPEX_PROFILE_PATH" "$APPEX_PATH/Contents/embedded.provisionprofile"

codesign -d --entitlements "$APP_ENTITLEMENTS" --xml "$APP_DST" >/dev/null 2>&1
codesign -d --entitlements "$APPEX_ENTITLEMENTS" --xml "$APPEX_PATH" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c 'Set :com.apple.developer.networking.networkextension:0 packet-tunnel-provider-systemextension' "$APP_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Set :com.apple.developer.networking.networkextension:0 packet-tunnel-provider-systemextension' "$APPEX_ENTITLEMENTS"

sign_frameworks_in "$APPEX_PATH"
sign_frameworks_in "$APP_DST"

codesign --force --timestamp --options runtime --entitlements "$APPEX_ENTITLEMENTS" --sign "$DEV_ID_IDENTITY" "$APPEX_PATH"
codesign --force --timestamp --options runtime --entitlements "$APP_ENTITLEMENTS" --sign "$DEV_ID_IDENTITY" "$APP_DST"
codesign --verify --deep --strict --verbose=2 "$APP_DST"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DST" "$ZIP_PATH"

xcrun notarytool submit \
  "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait \
  --output-format json >"$NOTARY_JSON"

xcrun stapler staple "$APP_DST"
xcrun stapler validate "$APP_DST"
spctl -a -vvv --type execute "$APP_DST"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DST" "$FINAL_ZIP"

if command -v plutil >/dev/null 2>&1; then
  echo "Submission ID: $(plutil -extract id raw -o - "$NOTARY_JSON")"
  echo "Status: $(plutil -extract status raw -o - "$NOTARY_JSON")"
fi
echo "Final artifact: $FINAL_ZIP"
