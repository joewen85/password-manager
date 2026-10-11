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
MARKETING_VERSION="${IOS_MARKETING_VERSION:-${MARKETING_VERSION:-0.1.0}}"
BUILD_NUMBER="${IOS_BUILD_NUMBER:-${BUILD_NUMBER:-1}}"
EXPECTED_SIGNING_CERT_SHA256="${IOS_EXPECTED_SIGNING_CERT_SHA256:-}"

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

normalize_sha256() {
  printf '%s' "$1" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]'
}

validate_versions() {
  if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    fail "IOS_MARKETING_VERSION must be one to three dot-separated integers, got '$MARKETING_VERSION'"
  fi

  if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    fail "IOS_BUILD_NUMBER must be one to three dot-separated integers, got '$BUILD_NUMBER'"
  fi

  if [[ -n "$EXPECTED_SIGNING_CERT_SHA256" && "$REQUIRE_SIGNED_ARCHIVE" != "true" ]]; then
    fail "IOS_EXPECTED_SIGNING_CERT_SHA256 requires IOS_REQUIRE_SIGNED_ARCHIVE=true"
  fi
}

verify_signing_certificate_sha256() {
  local app_bundle="$1"
  local expected_sha
  local actual_sha
  local cert_dir
  local cert_path

  expected_sha="$(normalize_sha256 "$EXPECTED_SIGNING_CERT_SHA256")"
  [[ -n "$expected_sha" ]] || return 0

  cert_dir="$(mktemp -d /tmp/password-manager-ios-codesign-cert.XXXXXX)"
  (cd "$cert_dir" && codesign -d --extract-certificates "$app_bundle" >/dev/null 2>&1) ||
    fail "Could not extract signing certificate from $app_bundle"
  cert_path="$cert_dir/codesign0"
  require_file "$cert_path"

  actual_sha="$(openssl x509 -inform DER -in "$cert_path" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
  actual_sha="$(normalize_sha256 "$actual_sha")"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    fail "Signing certificate SHA-256 mismatch: expected $EXPECTED_SIGNING_CERT_SHA256, got $actual_sha"
  ok "Signing certificate SHA-256 matches IOS_EXPECTED_SIGNING_CERT_SHA256"
}

cd "$ROOT_DIR"
validate_versions

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

"$ROOT_DIR/scripts/verify_ui_smoke.sh"

rm -rf "$APP_BUNDLE"
xcodebuild build \
  -project "$PROJECT" \
  -target PasswordManageriOS \
  -configuration Release \
  -sdk iphonesimulator \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO

require_file "$APP_BUNDLE/Info.plist"
require_file "$APP_BUNDLE/PrivacyInfo.xcprivacy"
require_file "$APP_BUNDLE/Assets.car"

require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleIdentifier" "life.devops.passwordmanager"
require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleDisplayName" "Password Manager"
require_plist_value "$APP_BUNDLE/Info.plist" "NSFaceIDUsageDescription" "Use Face ID to unlock Password Manager on this device."
require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleShortVersionString" "$MARKETING_VERSION"
require_plist_value "$APP_BUNDLE/Info.plist" "CFBundleVersion" "$BUILD_NUMBER"

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
      MARKETING_VERSION="$MARKETING_VERSION"
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
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
    archive_args+=(
      MARKETING_VERSION="$MARKETING_VERSION"
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
      CODE_SIGNING_ALLOWED=NO
    )
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
require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:CFBundleShortVersionString" "$MARKETING_VERSION"
require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:CFBundleVersion" "$BUILD_NUMBER"
require_plist_value "$ARCHIVE_PATH/Info.plist" "ApplicationProperties:Architectures:0" "arm64"

require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleIdentifier" "life.devops.passwordmanager"
require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleDisplayName" "Password Manager"
require_plist_value "$ARCHIVE_APP/Info.plist" "NSFaceIDUsageDescription" "Use Face ID to unlock Password Manager on this device."
require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleShortVersionString" "$MARKETING_VERSION"
require_plist_value "$ARCHIVE_APP/Info.plist" "CFBundleVersion" "$BUILD_NUMBER"

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
  verify_signing_certificate_sha256 "$ARCHIVE_APP"
  ok "Signed iOS archive passed codesign verification"
else
  if codesign --verify --deep --strict "$ARCHIVE_APP" >/dev/null 2>&1; then
    fail "Unsigned archive mode produced a signed app unexpectedly"
  fi
  ok "Unsigned iOS archive contract is explicit"
fi

ok "Generic iOS archive includes arm64 app, Info.plist, privacy manifest, Assets.car, and dSYM"
