#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PRODUCT_NAME="PasswordManagerMacOS"
APP_NAME="${APP_NAME:-Password Manager}"
BUNDLE_ID="${BUNDLE_ID:-life.dev-ops.passwordmanager}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
EXPECTED_SIGNING_CERT_SHA256="${EXPECTED_SIGNING_CERT_SHA256:-}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
DERIVED_APP_DIR="$APP_ROOT/dist/release"
APP_BUNDLE="$DERIVED_APP_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
ENTITLEMENTS="${ENTITLEMENTS:-$APP_ROOT/ReleaseSupport/PasswordManagerMacOS.entitlements}"
INFO_TEMPLATE="$APP_ROOT/ReleaseSupport/Info.plist"
PRIVACY_MANIFEST="$APP_ROOT/ReleaseSupport/PrivacyInfo.xcprivacy"
ICON_NAME="${ICON_NAME:-AppIcon}"
ICON_SCRIPT="$APP_ROOT/scripts/generate_app_icon.swift"
ICONSET_DIR="$DERIVED_APP_DIR/$ICON_NAME.iconset"
ICON_FILE="$CONTENTS_DIR/Resources/$ICON_NAME.icns"
RESOURCE_BUNDLE_NAME="${PRODUCT_NAME}_PasswordManagerMacOSApp.bundle"
RESOURCE_BUNDLE_SOURCE="$APP_ROOT/.build/release/$RESOURCE_BUNDLE_NAME"
RESOURCE_BUNDLE_DEST="$CONTENTS_DIR/Resources/$RESOURCE_BUNDLE_NAME"
CODESIGN_TIMESTAMP_FLAGS=()

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [MARKETING_VERSION] [BUILD_NUMBER]
  $(basename "$0") --version <MARKETING_VERSION> --build-number <BUILD_NUMBER>

Options:
  --version, --marketing-version <value>  Set CFBundleShortVersionString, for example 1.0.0.
  --build-number, --build <value>         Set CFBundleVersion, for example 100.
  -h, --help                             Show this help.

Environment variables remain supported:
  MARKETING_VERSION=1.0.0 BUILD_NUMBER=100 $(basename "$0")
EOF
}

require_option_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for $option." >&2
    usage >&2
    exit 2
  fi
}

parse_args() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version|--marketing-version)
        require_option_value "$1" "${2:-}"
        MARKETING_VERSION="$2"
        shift 2
        ;;
      --version=*|--marketing-version=*)
        MARKETING_VERSION="${1#*=}"
        shift
        ;;
      --build-number|--build)
        require_option_value "$1" "${2:-}"
        BUILD_NUMBER="$2"
        shift 2
        ;;
      --build-number=*|--build=*)
        BUILD_NUMBER="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          positional+=("$1")
          shift
        done
        ;;
      -*)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -gt 2 ]]; then
    echo "Too many positional arguments." >&2
    usage >&2
    exit 2
  fi

  if [[ ${#positional[@]} -ge 1 ]]; then
    MARKETING_VERSION="${positional[0]}"
  fi
  if [[ ${#positional[@]} -ge 2 ]]; then
    BUILD_NUMBER="${positional[1]}"
  fi
}

validate_versions() {
  if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Invalid MARKETING_VERSION: $MARKETING_VERSION" >&2
    echo "Use one to three dot-separated integers, for example 1.0.0." >&2
    exit 2
  fi

  if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Invalid BUILD_NUMBER: $BUILD_NUMBER" >&2
    echo "Use one to three dot-separated integers, for example 100." >&2
    exit 2
  fi
}

parse_args "$@"
validate_versions

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  CODESIGN_TIMESTAMP_FLAGS+=(--timestamp=none)
  ENTITLEMENTS=""
else
  CODESIGN_TIMESTAMP_FLAGS+=(--timestamp)
fi

normalize_sha256() {
  printf '%s' "$1" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]'
}

verify_signing_identity() {
  local app_bundle="$1"
  local signature_details="$2"

  if [[ -n "$EXPECTED_TEAM_ID" ]]; then
    local actual_team_id
    actual_team_id="$(awk -F= '/^TeamIdentifier=/ {print $2; exit}' <<<"$signature_details")"
    if [[ -z "$actual_team_id" ]]; then
      echo "Signed app does not expose a TeamIdentifier; cannot verify EXPECTED_TEAM_ID." >&2
      exit 1
    fi
    if [[ "$actual_team_id" != "$EXPECTED_TEAM_ID" ]]; then
      echo "Signing TeamIdentifier mismatch: expected $EXPECTED_TEAM_ID, got $actual_team_id." >&2
      exit 1
    fi
    echo "Signing TeamIdentifier matches EXPECTED_TEAM_ID: $actual_team_id"
  fi

  if [[ -n "$EXPECTED_SIGNING_CERT_SHA256" ]]; then
    if grep -q "Signature=adhoc" <<<"$signature_details"; then
      echo "Cannot verify EXPECTED_SIGNING_CERT_SHA256 for an ad-hoc signed app." >&2
      exit 1
    fi

    local cert_dir cert_path actual_sha expected_sha
    cert_dir="$(mktemp -d /tmp/password-manager-macos-codesign-cert.XXXXXX)"
    (cd "$cert_dir" && codesign -d --extract-certificates "$app_bundle" >/dev/null 2>&1)
    cert_path="$cert_dir/codesign0"
    if [[ ! -f "$cert_path" ]]; then
      echo "Could not extract leaf signing certificate from $app_bundle." >&2
      exit 1
    fi

    actual_sha="$(openssl x509 -inform DER -in "$cert_path" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
    actual_sha="$(normalize_sha256 "$actual_sha")"
    expected_sha="$(normalize_sha256 "$EXPECTED_SIGNING_CERT_SHA256")"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      echo "Signing certificate SHA-256 mismatch: expected $EXPECTED_SIGNING_CERT_SHA256, got $actual_sha." >&2
      exit 1
    fi
    echo "Signing certificate SHA-256 matches EXPECTED_SIGNING_CERT_SHA256: $actual_sha"
  fi
}

echo "Building $PRODUCT_NAME release executable..."
swift build -c release --package-path "$APP_ROOT"

echo "Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$APP_ROOT/.build/release/$PRODUCT_NAME" "$CONTENTS_DIR/MacOS/$PRODUCT_NAME"
chmod 755 "$CONTENTS_DIR/MacOS/$PRODUCT_NAME"
if [[ ! -d "$RESOURCE_BUNDLE_SOURCE" ]]; then
  echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE_SOURCE" >&2
  exit 1
fi
rm -rf "$RESOURCE_BUNDLE_DEST"
cp -R "$RESOURCE_BUNDLE_SOURCE" "$CONTENTS_DIR/Resources/"
cp "$INFO_TEMPLATE" "$INFO_PLIST"
cp "$PRIVACY_MANIFEST" "$CONTENTS_DIR/Resources/PrivacyInfo.xcprivacy"

echo "Generating app icon..."
rm -rf "$ICONSET_DIR"
swift "$ICON_SCRIPT" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"

echo "Signing $APP_BUNDLE with identity: $SIGN_IDENTITY"
if [[ -n "$ENTITLEMENTS" ]]; then
  echo "Using entitlements: $ENTITLEMENTS"
  codesign \
    --force \
    "${CODESIGN_TIMESTAMP_FLAGS[@]}" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
else
  echo "Using entitlements: none"
  codesign \
    --force \
    "${CODESIGN_TIMESTAMP_FLAGS[@]}" \
    --options runtime \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
fi

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dvvv --entitlements :- "$APP_BUNDLE" >/dev/null
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
verify_signing_identity "$APP_BUNDLE" "$SIGNATURE_DETAILS"

echo "Creating local zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$DERIVED_APP_DIR/$APP_NAME.zip"

if spctl --assess --type execute --verbose=2 "$APP_BUNDLE"; then
  echo "Gatekeeper assessment passed."
else
  echo "Gatekeeper assessment did not pass. This is expected for ad-hoc signing; use SIGN_IDENTITY='Developer ID Application: ...' and notarize for external distribution." >&2
fi

echo "Packaged app: $APP_BUNDLE"
echo "Archive: $DERIVED_APP_DIR/$APP_NAME.zip"
echo "Version: $MARKETING_VERSION ($BUILD_NUMBER)"
