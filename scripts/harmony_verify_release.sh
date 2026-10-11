#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/harmony_app"
PRODUCT="${HARMONY_RELEASE_PRODUCT:-default}"
RUN_UNSIGNED="${HARMONY_RELEASE_UNSIGNED:-1}"
RUN_SIGNED="${HARMONY_RELEASE_SIGNED:-0}"
RUN_SMOKE="${HARMONY_RELEASE_SMOKE:-0}"
SIGN_ENV_FILE="${HARMONY_SIGN_ENV_FILE:-}"
SMOKE_BUNDLE_NAME="${HARMONY_RELEASE_BUNDLE_NAME:-life.devops.passwordmanager}"

source "$ROOT_DIR/scripts/harmony_env.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Runs the Harmony release gate:
  preflight -> unsigned build + HAP verify -> optional signed build + HAP verify -> optional device smoke

Options:
  --product <name>       Hvigor product name (default: $PRODUCT)
  --unsigned             Run unsigned build gate (default)
  --skip-unsigned        Skip unsigned build gate
  --signed               Run signed build gate (default: off)
  --skip-signed          Skip signed build gate
  --smoke                Run install/launch smoke after the selected build (default: off)
  --skip-smoke           Skip install/launch smoke
  --env-file <path>      Signing env file passed to harmony_build_signed_hap.sh
  -h, --help             Show this help

Environment defaults:
  HARMONY_RELEASE_PRODUCT=$PRODUCT
  HARMONY_RELEASE_UNSIGNED=$RUN_UNSIGNED
  HARMONY_RELEASE_SIGNED=$RUN_SIGNED
  HARMONY_RELEASE_SMOKE=$RUN_SMOKE
  HARMONY_RELEASE_BUNDLE_NAME=$SMOKE_BUNDLE_NAME
EOF
}

fail() {
  printf "[FAIL] %s\n" "$1" >&2
  exit 1
}

info() {
  printf "[INFO] %s\n" "$1"
}

ok() {
  printf "[OK] %s\n" "$1"
}

normalize_bool() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) printf "1" ;;
    0|false|FALSE|no|NO|off|OFF) printf "0" ;;
    *) fail "Boolean value must be one of 1/0, true/false, yes/no, on/off: $1" ;;
  esac
}

find_hap() {
  local signature="$1"
  local hap

  hap="$(find "$APP_DIR/entry/build" -type f -name "*-${signature}.hap" 2>/dev/null | sort | head -n 1 || true)"
  if [[ -z "$hap" ]]; then
    hap="$(find "$APP_DIR/entry/build" -type f -name "*.hap" 2>/dev/null | sort | head -n 1 || true)"
  fi

  [[ -n "$hap" ]] || fail "No HAP artifact found after $signature build"
  printf "%s" "$hap"
}

run_unsigned_gate() {
  local hap_path

  info "Cleaning previous Harmony build outputs"
  rm -rf "$APP_DIR/entry/build"

  info "Running unsigned HAP build gate"
  HARMONY_EXPECT_HAP_SIGNATURE=unsigned "$ROOT_DIR/scripts/harmony_build_hap.sh" "$PRODUCT"

  hap_path="$(find_hap unsigned)"
  info "Verifying unsigned HAP: $hap_path"
  "$ROOT_DIR/scripts/harmony_verify_hap.sh" --expect-signature unsigned "$hap_path"

  RELEASE_HAP_PATH="$hap_path"
}

run_signed_gate() {
  local hap_path
  local signed_args=()

  if [[ -n "$SIGN_ENV_FILE" ]]; then
    signed_args+=(--env-file "$SIGN_ENV_FILE")
  fi

  info "Running signed HAP build gate"
  "$ROOT_DIR/scripts/harmony_build_signed_hap.sh" "${signed_args[@]}"

  hap_path="$(find_hap signed)"
  info "Verifying signed HAP: $hap_path"
  "$ROOT_DIR/scripts/harmony_verify_hap.sh" --expect-signature signed "$hap_path"

  RELEASE_HAP_PATH="$hap_path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product)
      [[ $# -ge 2 ]] || fail "--product requires a value"
      PRODUCT="$2"
      shift 2
      ;;
    --unsigned)
      RUN_UNSIGNED=1
      shift
      ;;
    --skip-unsigned)
      RUN_UNSIGNED=0
      shift
      ;;
    --signed)
      RUN_SIGNED=1
      shift
      ;;
    --skip-signed)
      RUN_SIGNED=0
      shift
      ;;
    --smoke)
      RUN_SMOKE=1
      shift
      ;;
    --skip-smoke)
      RUN_SMOKE=0
      shift
      ;;
    --env-file)
      [[ $# -ge 2 ]] || fail "--env-file requires a path"
      SIGN_ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

RUN_UNSIGNED="$(normalize_bool "$RUN_UNSIGNED")"
RUN_SIGNED="$(normalize_bool "$RUN_SIGNED")"
RUN_SMOKE="$(normalize_bool "$RUN_SMOKE")"

if [[ "$RUN_UNSIGNED" == "0" && "$RUN_SIGNED" == "0" ]]; then
  fail "At least one build gate must run; enable --unsigned or --signed"
fi

RELEASE_HAP_PATH=""

echo "== HarmonyOS Release Verification Gate =="
info "product=$PRODUCT"
info "unsigned=$RUN_UNSIGNED signed=$RUN_SIGNED smoke=$RUN_SMOKE"

"$ROOT_DIR/scripts/harmony_preflight.sh"

if [[ "$RUN_UNSIGNED" == "1" ]]; then
  run_unsigned_gate
fi

if [[ "$RUN_SIGNED" == "1" ]]; then
  run_signed_gate
fi

if [[ "$RUN_SMOKE" == "1" ]]; then
  [[ -n "$RELEASE_HAP_PATH" ]] || fail "No HAP artifact selected for smoke"
  info "Running device smoke with HAP: $RELEASE_HAP_PATH"
  "$ROOT_DIR/scripts/harmony_device_smoke.sh" "$RELEASE_HAP_PATH" "$SMOKE_BUNDLE_NAME"
fi

ok "Harmony release verification gate passed"
ok "Release HAP: $RELEASE_HAP_PATH"
