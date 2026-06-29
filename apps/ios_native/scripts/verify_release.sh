#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/PasswordManageriOS.xcodeproj"
APPICON_JSON="$ROOT_DIR/PasswordManageriOS/Assets.xcassets/AppIcon.appiconset/Contents.json"
APPICON_DIR="$ROOT_DIR/PasswordManageriOS/Assets.xcassets/AppIcon.appiconset"
APPICON_PNG="$APPICON_DIR/Icon-App-1024x1024@1x.png"
PRIVACY_MANIFEST="$ROOT_DIR/PasswordManageriOS/PrivacyInfo.xcprivacy"
APP_BUNDLE="$ROOT_DIR/build/Release-iphonesimulator/PasswordManageriOS.app"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

ok() {
  printf '[OK] %s\n' "$1"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing file: $path"
}

require_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || fail "$key expected '$expected' but found '$actual'"
}

cd "$ROOT_DIR"

require_file "$PROJECT/project.pbxproj"
require_file "$PRIVACY_MANIFEST"
require_file "$APPICON_JSON"
require_file "$APPICON_PNG"

plutil -lint "$PRIVACY_MANIFEST" >/dev/null
ok "Privacy manifest is valid"

if ! grep -q "NSPrivacyAccessedAPICategoryUserDefaults" "$PRIVACY_MANIFEST"; then
  fail "Privacy manifest must declare UserDefaults required-reason API usage"
fi
if ! grep -q "CA92.1" "$PRIVACY_MANIFEST"; then
  fail "Privacy manifest must include CA92.1 for app-only UserDefaults storage"
fi
ok "Privacy manifest declares UserDefaults CA92.1"

if ! grep -q '"filename" : "Icon-App-1024x1024@1x.png"' "$APPICON_JSON"; then
  fail "AppIcon catalog must reference Icon-App-1024x1024@1x.png"
fi
if ! file "$APPICON_PNG" | grep -q "PNG image data, 1024 x 1024"; then
  fail "Icon-App-1024x1024@1x.png must be a 1024x1024 PNG"
fi
for icon in \
  "Icon-App-20x20@2x.png" \
  "Icon-App-29x29@3x.png" \
  "Icon-App-60x60@3x.png" \
  "Icon-App-76x76@2x.png" \
  "Icon-App-83.5x83.5@2x.png"; do
  require_file "$APPICON_DIR/$icon"
done
ok "App icon catalog has required iPhone/iPad PNGs"

swift test

rm -rf "$APP_BUNDLE"
xcodebuild build \
  -project "$PROJECT" \
  -target PasswordManageriOS \
  -configuration Release \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO

require_file "$APP_BUNDLE/Info.plist"
require_file "$APP_BUNDLE/PrivacyInfo.xcprivacy"
require_file "$APP_BUNDLE/Assets.car"

require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleIdentifier" "life.devops.passwordmanager"
require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleDisplayName" "Password Manager"
require_plist_value "$APP_BUNDLE/Info.plist" "NSFaceIDUsageDescription" "Use Face ID to unlock Password Manager on this device."

if ! grep -q "NSPrivacyAccessedAPICategoryUserDefaults" "$APP_BUNDLE/PrivacyInfo.xcprivacy"; then
  fail "Built app privacy manifest is missing UserDefaults disclosure"
fi
if ! grep -q "CA92.1" "$APP_BUNDLE/PrivacyInfo.xcprivacy"; then
  fail "Built app privacy manifest is missing CA92.1"
fi

ok "Release simulator build includes Info.plist, privacy manifest, and Assets.car"
