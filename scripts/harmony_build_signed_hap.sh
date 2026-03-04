#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/harmony_app"
BUILD_PROFILE="$APP_DIR/build-profile.json5"
DEFAULT_ENV_FILE="$APP_DIR/signing/signing.env"
ENV_FILE="${HARMONY_SIGN_ENV_FILE:-$DEFAULT_ENV_FILE}"
source "$ROOT_DIR/scripts/harmony_env.sh"

required_env=(
  HARMONY_SIGN_STORE_FILE
  HARMONY_SIGN_STORE_PASSWORD
  HARMONY_SIGN_KEY_ALIAS
  HARMONY_SIGN_KEY_PASSWORD
  HARMONY_SIGN_PROFILE
  HARMONY_SIGN_CERTPATH
)

fail() { printf "[FAIL] %s\n" "$1"; }
info() { printf "[INFO] %s\n" "$1"; }
warn() { printf "[WARN] %s\n" "$1"; }

usage() {
  cat <<EOF
Usage: $0 [--env-file <path>]

Options:
  --env-file <path>  Signing env file path (default: $DEFAULT_ENV_FILE)

Env keys required:
  HARMONY_SIGN_STORE_FILE
  HARMONY_SIGN_STORE_PASSWORD
  HARMONY_SIGN_KEY_ALIAS
  HARMONY_SIGN_KEY_PASSWORD
  HARMONY_SIGN_PROFILE
  HARMONY_SIGN_CERTPATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        fail "--env-file requires a path"
        usage
        exit 1
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  info "Loading signing env file: $ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
elif [[ "$ENV_FILE" == "$DEFAULT_ENV_FILE" && -f "$APP_DIR/signing/signing.env.example" ]]; then
  info "Generating signing env from template: $ENV_FILE"
  mkdir -p "$(dirname "$ENV_FILE")"
  cp "$APP_DIR/signing/signing.env.example" "$ENV_FILE"
  warn "Please edit $ENV_FILE with your real signing materials, then rerun."
  exit 1
elif [[ "$ENV_FILE" != "$DEFAULT_ENV_FILE" ]]; then
  fail "Signing env file not found: $ENV_FILE"
  exit 1
else
  warn "Signing env file not found (optional): $ENV_FILE"
fi

missing_keys=()
placeholder_keys=()

is_placeholder_value() {
  local value="$1"
  case "$value" in
    ""|change_me|*"/absolute/path/to/"*|your_*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

for key in "${required_env[@]}"; do
  value="${!key:-}"
  if [[ -z "$value" ]]; then
    missing_keys+=("$key")
  elif is_placeholder_value "$value"; then
    placeholder_keys+=("$key")
  fi
done

if [[ ${#missing_keys[@]} -gt 0 ]]; then
  if rg -q '"signingConfig"\s*:\s*"[^\"]+"' "$BUILD_PROFILE" \
    && ! rg -q '"signingConfigs"\s*:\s*\[\s*\]' "$BUILD_PROFILE"; then
    warn "Signing env incomplete, fallback to existing signing config in build-profile.json5"
    "$ROOT_DIR/scripts/harmony_build_hap.sh" default
    exit 0
  else
    fail "Missing signing variables: ${missing_keys[*]}"
    if [[ -f "$APP_DIR/signing/signing.env.example" ]]; then
      info "Create your config file:"
      info "  cp \"$APP_DIR/signing/signing.env.example\" \"$APP_DIR/signing/signing.env\""
      info "  # then edit signing.env with your real signing materials"
    fi
    exit 1
  fi
fi

if [[ ${#placeholder_keys[@]} -gt 0 ]]; then
  fail "Unconfigured signing variables in env file: ${placeholder_keys[*]}"
  info "Please edit: $ENV_FILE"
  exit 1
fi

file_env=(
  HARMONY_SIGN_STORE_FILE
  HARMONY_SIGN_PROFILE
  HARMONY_SIGN_CERTPATH
)

for key in "${file_env[@]}"; do
  path="${!key}"
  if [[ ! -f "$path" ]]; then
    fail "$key file not found: $path"
    exit 1
  fi
done

if [[ ! -f "$BUILD_PROFILE" ]]; then
  fail "Missing build profile: $BUILD_PROFILE"
  exit 1
fi

backup="$(mktemp "$APP_DIR/.build-profile.backup.XXXXXX")"
cp "$BUILD_PROFILE" "$backup"

restore_build_profile() {
  if [[ -f "$backup" ]]; then
    cp "$backup" "$BUILD_PROFILE"
    rm -f "$backup"
  fi
}
trap restore_build_profile EXIT

info "Generating temporary signed build-profile.json5"
cat >"$BUILD_PROFILE" <<EOF
{
  "app": {
    "signingConfigs": [
      {
        "name": "release",
        "type": "HarmonyOS",
        "material": {
          "storeFile": "${HARMONY_SIGN_STORE_FILE}",
          "storePassword": "${HARMONY_SIGN_STORE_PASSWORD}",
          "keyAlias": "${HARMONY_SIGN_KEY_ALIAS}",
          "keyPassword": "${HARMONY_SIGN_KEY_PASSWORD}",
          "signAlg": "SHA256withECDSA",
          "profile": "${HARMONY_SIGN_PROFILE}",
          "certpath": "${HARMONY_SIGN_CERTPATH}"
        }
      }
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "release",
        "runtimeOS": "HarmonyOS",
        "compileSdkVersion": "6.0.1(21)",
        "compatibleSdkVersion": "6.0.1(21)",
        "targetSdkVersion": "6.0.1(21)",
        "buildOption": {
          "strictMode": {
            "useNormalizedOHMUrl": true
          }
        }
      }
    ]
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        {
          "name": "default",
          "applyToProducts": ["default"]
        }
      ]
    }
  ]
}
EOF

info "Running signed assembleHap build"
"$ROOT_DIR/scripts/harmony_build_hap.sh" default

info "Signed build flow completed (build-profile restored)"
