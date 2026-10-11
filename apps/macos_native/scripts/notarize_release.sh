#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-Password Manager}"
DERIVED_APP_DIR="$APP_ROOT/dist/release"
APP_BUNDLE="${APP_BUNDLE:-$DERIVED_APP_DIR/$APP_NAME.app}"
ARCHIVE="${ARCHIVE:-$DERIVED_APP_DIR/$APP_NAME.zip}"
EXPECTED_SIGNING_CERT_SHA256="${EXPECTED_SIGNING_CERT_SHA256:-}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"

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

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "App bundle not found: $APP_BUNDLE" >&2
  echo "Run SIGN_IDENTITY='Developer ID Application: ...' ./scripts/package_release.sh first." >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Archive not found: $ARCHIVE" >&2
  echo "Run ./scripts/package_release.sh first, or set ARCHIVE=/path/to/app.zip." >&2
  exit 1
fi

SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application:" <<<"$SIGNATURE_DETAILS"; then
  echo "The app is not signed with a Developer ID Application certificate." >&2
  echo "Notarization requires Developer ID signing, not the default ad-hoc identity." >&2
  echo "Run SIGN_IDENTITY='Developer ID Application: ...' ./scripts/package_release.sh first." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
verify_signing_identity "$APP_BUNDLE" "$SIGNATURE_DETAILS"

NOTARY_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
  NOTARY_ARGS+=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD")
else
  echo "Missing notarization credentials." >&2
  echo "Set NOTARY_KEYCHAIN_PROFILE, or set APPLE_ID, TEAM_ID, and APP_SPECIFIC_PASSWORD." >&2
  exit 1
fi

echo "Submitting $ARCHIVE for notarization..."
xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait

echo "Stapling notarization ticket to $APP_BUNDLE..."
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

echo "Assessing Gatekeeper trust..."
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

echo "Notarized app: $APP_BUNDLE"
