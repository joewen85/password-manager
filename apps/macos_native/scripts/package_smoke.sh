#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$APP_ROOT"

APP_NAME="${APP_NAME:-Password Manager}"
PRODUCT_NAME="PasswordManagerMacOS"
DERIVED_APP_DIR="$APP_ROOT/dist/release"
APP_BUNDLE="$DERIVED_APP_DIR/$APP_NAME.app"
ARCHIVE="$DERIVED_APP_DIR/$APP_NAME.zip"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-${BUNDLE_ID:-life.devops.passwordmanager}}"
CONTENTS_DIR="$APP_BUNDLE/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
RESOURCE_BUNDLE_NAME="${PRODUCT_NAME}_PasswordManagerMacOSApp.bundle"
RESOURCE_BUNDLE_PATH="$RESOURCES_DIR/$RESOURCE_BUNDLE_NAME"

echo "Running macOS package smoke..."
swift test
./scripts/package_release.sh

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Missing archive: $ARCHIVE" >&2
  exit 1
fi

PLIST_BUDDY=/usr/libexec/PlistBuddy
BUNDLE_ID="$("$PLIST_BUDDY" -c "Print :CFBundleIdentifier" "$CONTENTS_DIR/Info.plist")"
ICON_FILE="$("$PLIST_BUDDY" -c "Print :CFBundleIconFile" "$CONTENTS_DIR/Info.plist")"
SHORT_VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$CONTENTS_DIR/Info.plist")"
BUILD_NUMBER="$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$CONTENTS_DIR/Info.plist")"

if [[ -z "$BUNDLE_ID" || -z "$ICON_FILE" || -z "$SHORT_VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "Bundle metadata is incomplete." >&2
  exit 1
fi

if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID, got $BUNDLE_ID." >&2
  exit 1
fi

if [[ ! -f "$RESOURCES_DIR/$ICON_FILE.icns" ]]; then
  echo "Missing app icon: $RESOURCES_DIR/$ICON_FILE.icns" >&2
  exit 1
fi

if [[ ! -f "$RESOURCES_DIR/PrivacyInfo.xcprivacy" ]]; then
  echo "Missing privacy manifest: $RESOURCES_DIR/PrivacyInfo.xcprivacy" >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
  echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE_PATH" >&2
  exit 1
fi

plutil -lint "$CONTENTS_DIR/Info.plist" "$RESOURCES_DIR/PrivacyInfo.xcprivacy" "$APP_ROOT/ReleaseSupport/PasswordManagerMacOS.entitlements"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_BUNDLE" 2>/dev/null)"
if grep -q "com.apple.security.app-sandbox" <<<"$SIGNED_ENTITLEMENTS"; then
  echo "Ad-hoc local package unexpectedly has App Sandbox; Keychain writes can fail with errSecMissingEntitlement." >&2
  exit 1
fi

ICONSET_CHECK_ROOT="$(mktemp -d /tmp/password-manager-macos-iconset.XXXXXX)"
ICONSET_CHECK_DIR="$ICONSET_CHECK_ROOT/$ICON_FILE.iconset"
iconutil -c iconset "$RESOURCES_DIR/$ICON_FILE.icns" -o "$ICONSET_CHECK_DIR"
ICON_COUNT="$(find "$ICONSET_CHECK_DIR" -type f -name '*.png' | wc -l | tr -d '[:space:]')"
if [[ "$ICON_COUNT" != "10" ]]; then
  echo "Expected 10 iconset PNGs after expanding icns, found $ICON_COUNT." >&2
  exit 1
fi

ZIP_CHECK_DIR="$(mktemp -d /tmp/password-manager-macos-zipcheck.XXXXXX)"
ditto -x -k "$ARCHIVE" "$ZIP_CHECK_DIR"
codesign --verify --deep --strict --verbose=2 "$ZIP_CHECK_DIR/$APP_NAME.app"
if [[ ! -f "$ZIP_CHECK_DIR/$APP_NAME.app/Contents/Resources/$ICON_FILE.icns" ]]; then
  echo "Zip archive is missing app icon." >&2
  exit 1
fi
if [[ ! -f "$ZIP_CHECK_DIR/$APP_NAME.app/Contents/Resources/PrivacyInfo.xcprivacy" ]]; then
  echo "Zip archive is missing privacy manifest." >&2
  exit 1
fi
if [[ ! -d "$ZIP_CHECK_DIR/$APP_NAME.app/Contents/Resources/$RESOURCE_BUNDLE_NAME" ]]; then
  echo "Zip archive is missing SwiftPM resource bundle." >&2
  exit 1
fi

echo "Launching packaged app for smoke validation..."
open -n "$APP_BUNDLE"
APP_PID=""
for _ in {1..20}; do
  APP_PID="$(pgrep -f "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME" | head -n 1 || true)"
  if [[ -n "$APP_PID" ]]; then
    break
  fi
  sleep 0.5
done

if [[ -z "$APP_PID" ]]; then
  echo "Packaged app did not start." >&2
  exit 1
fi

kill "$APP_PID" 2>/dev/null || true
sleep 1
if ps -p "$APP_PID" >/dev/null 2>&1; then
  kill -9 "$APP_PID" 2>/dev/null || true
fi

echo "bundleId=$BUNDLE_ID"
echo "version=$SHORT_VERSION"
echo "build=$BUILD_NUMBER"
echo "icon=$RESOURCES_DIR/$ICON_FILE.icns"
echo "privacy=$RESOURCES_DIR/PrivacyInfo.xcprivacy"
echo "archive=$ARCHIVE"
echo "launchPid=$APP_PID"
echo "macOS package smoke completed."
