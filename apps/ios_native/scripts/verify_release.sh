#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/PasswordManageriOS.xcodeproj"
APPICON_JSON="$ROOT_DIR/PasswordManageriOS/Assets.xcassets/AppIcon.appiconset/Contents.json"
APPICON_DIR="$ROOT_DIR/PasswordManageriOS/Assets.xcassets/AppIcon.appiconset"
APPICON_PNG="$APPICON_DIR/Icon-App-1024x1024@1x.png"
PRIVACY_MANIFEST="$ROOT_DIR/PasswordManageriOS/PrivacyInfo.xcprivacy"
APP_BUNDLE="$ROOT_DIR/build/Release-iphonesimulator/PasswordManageriOS.app"
ARCHIVE_PATH="$ROOT_DIR/build/PasswordManageriOS.xcarchive"
ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/PasswordManageriOS.app"
REQUIRE_SIGNED_ARCHIVE="${IOS_REQUIRE_SIGNED_ARCHIVE:-false}"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

ok() {
  printf '[OK] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1"
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

require_plist_nonempty() {
  local plist="$1"
  local key="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  [[ -n "$actual" ]] || fail "$key must not be empty"
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
require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleShortVersionString" "0.1.0"
require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleVersion" "1"

if ! grep -q "NSPrivacyAccessedAPICategoryUserDefaults" "$APP_BUNDLE/PrivacyInfo.xcprivacy"; then
  fail "Built app privacy manifest is missing UserDefaults disclosure"
fi
if ! grep -q "CA92.1" "$APP_BUNDLE/PrivacyInfo.xcprivacy"; then
  fail "Built app privacy manifest is missing CA92.1"
fi

ok "Release simulator build includes Info.plist, privacy manifest, and Assets.car"
"$ROOT_DIR/scripts/verify_simulator_smoke.sh" "$APP_BUNDLE"

rm -rf "$ARCHIVE_PATH"

archive_args=(
  archive
  -project "$PROJECT"
  -scheme PasswordManageriOS
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
)

case "$REQUIRE_SIGNED_ARCHIVE" in
  true)
    [[ -n "${IOS_DEVELOPMENT_TEAM:-}" ]] || fail "IOS_DEVELOPMENT_TEAM is required when IOS_REQUIRE_SIGNED_ARCHIVE=true"
    archive_args+=(
      DEVELOPMENT_TEAM="$IOS_DEVELOPMENT_TEAM"
      CODE_SIGNING_ALLOWED=YES
    )
    if [[ -n "${IOS_CODE_SIGN_IDENTITY:-}" ]]; then
      archive_args+=(CODE_SIGN_IDENTITY="$IOS_CODE_SIGN_IDENTITY")
    fi
    if [[ -n "${IOS_PROVISIONING_PROFILE_SPECIFIER:-}" ]]; then
      archive_args+=(PROVISIONING_PROFILE_SPECIFIER="$IOS_PROVISIONING_PROFILE_SPECIFIER")
    fi
    if [[ "${IOS_ALLOW_PROVISIONING_UPDATES:-false}" == "true" ]]; then
      archive_args+=(-allowProvisioningUpdates)
    fi
    ;;
  false)
    archive_args+=(CODE_SIGNING_ALLOWED=NO)
    warn "Building unsigned generic iOS archive; set IOS_REQUIRE_SIGNED_ARCHIVE=true to require Apple signing"
    ;;
  *)
    fail "IOS_REQUIRE_SIGNED_ARCHIVE must be true or false"
    ;;
esac

xcodebuild "${archive_args[@]}"

require_file "$ARCHIVE_PATH/Info.plist"
require_file "$ARCHIVE_APP/Info.plist"
require_file "$ARCHIVE_APP/PrivacyInfo.xcprivacy"
require_file "$ARCHIVE_APP/Assets.car"
require_file "$ARCHIVE_APP/PasswordManageriOS"
require_file "$ARCHIVE_PATH/dSYMs/PasswordManageriOS.app.dSYM/Contents/Info.plist"

require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:ApplicationPath" "Applications/PasswordManageriOS.app"
require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:CFBundleIdentifier" "life.devops.passwordmanager"
require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:CFBundleShortVersionString" "0.1.0"
require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:CFBundleVersion" "1"
require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:Architectures:0" "arm64"

require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleIdentifier" "life.devops.passwordmanager"
require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleDisplayName" "Password Manager"
require_plist_value "$ARCHIVE_APP/Info.plist" "NSFaceIDUsageDescription" "Use Face ID to unlock Password Manager on this device."
require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleShortVersionString" "0.1.0"
require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleVersion" "1"

if ! lipo -info "$ARCHIVE_APP/PasswordManageriOS" | grep -q "arm64"; then
  fail "Archived app binary must include arm64"
fi
if ! grep -q "NSPrivacyAccessedAPICategoryUserDefaults" "$ARCHIVE_APP/PrivacyInfo.xcprivacy"; then
  fail "Archived app privacy manifest is missing UserDefaults disclosure"
fi
if ! grep -q "CA92.1" "$ARCHIVE_APP/PrivacyInfo.xcprivacy"; then
  fail "Archived app privacy manifest is missing CA92.1"
fi

if [[ "$REQUIRE_SIGNED_ARCHIVE" == "true" ]]; then
  require_file "$ARCHIVE_APP/_CodeSignature/CodeResources"
  codesign --verify --deep --strict --verbose=2 "$ARCHIVE_APP"
  require_plist_nonempty "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:SigningIdentity"
  require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:Team" "$IOS_DEVELOPMENT_TEAM"
  ok "Signed iOS archive passed codesign verification"
else
  if codesign --verify --deep --strict "$ARCHIVE_APP" >/dev/null 2>&1; then
    fail "Unsigned archive mode produced a signed app unexpectedly"
  fi
  ok "Unsigned iOS archive contract is explicit"
fi

ok "Generic iOS archive includes arm64 app, Info.plist, privacy manifest, Assets.car, and dSYM"
