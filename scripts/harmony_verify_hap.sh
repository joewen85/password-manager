#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_BUNDLE_NAME="${EXPECTED_BUNDLE_NAME:-life.devops.passwordmanager}"
EXPECTED_VENDOR="${EXPECTED_VENDOR:-DevOps Life}"
EXPECTED_SIGNATURE="${EXPECTED_SIGNATURE:-any}"
HAP_PATH=""

source "$ROOT_DIR/scripts/harmony_env.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--expect-signature signed|unsigned|any] <path-to-hap>

Validates Harmony HAP release metadata and, when requested, verifies whether the
artifact is signed with the Harmony hap-sign-tool.
EOF
}

fail() {
  printf "[FAIL] %s\n" "$1" >&2
  exit 1
}

ok() {
  printf "[OK] %s\n" "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-signature)
      [[ $# -ge 2 ]] || fail "--expect-signature requires signed, unsigned, or any"
      EXPECTED_SIGNATURE="$2"
      shift 2
      ;;
    --expect-signature=*)
      EXPECTED_SIGNATURE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "Unknown argument: $1"
      ;;
    *)
      if [[ -n "$HAP_PATH" ]]; then
        fail "Only one HAP path may be provided"
      fi
      HAP_PATH="$1"
      shift
      ;;
  esac
done

case "$EXPECTED_SIGNATURE" in
  signed|unsigned|any) ;;
  *) fail "--expect-signature must be signed, unsigned, or any" ;;
esac

[[ -n "$HAP_PATH" ]] || fail "Missing HAP path"
[[ -f "$HAP_PATH" ]] || fail "HAP file does not exist: $HAP_PATH"

command -v unzip >/dev/null 2>&1 || fail "unzip is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

VERIFY_TMP="$(mktemp -d /tmp/password-manager-harmony-hap-verify.XXXXXX)"
cleanup() {
  rm -rf "$VERIFY_TMP"
}
trap cleanup EXIT

unzip -p "$HAP_PATH" pack.info >"$VERIFY_TMP/pack.info" \
  || fail "HAP is missing pack.info"
unzip -p "$HAP_PATH" module.json >"$VERIFY_TMP/module.json" \
  || fail "HAP is missing module.json"

python3 - "$VERIFY_TMP/pack.info" "$VERIFY_TMP/module.json" "$EXPECTED_BUNDLE_NAME" "$EXPECTED_VENDOR" <<'PY'
import json
import re
import sys

pack_path, module_path, expected_bundle, expected_vendor = sys.argv[1:5]

with open(pack_path, "r", encoding="utf-8") as handle:
    pack = json.load(handle)
with open(module_path, "r", encoding="utf-8") as handle:
    module = json.load(handle)

def fail(message: str) -> None:
    raise SystemExit(message)

summary_app = pack.get("summary", {}).get("app", {})
if summary_app.get("bundleName") != expected_bundle:
    fail(f"pack.info bundleName must be {expected_bundle}")

version = summary_app.get("version", {})
if not isinstance(version.get("code"), int) or version["code"] <= 0:
    fail("pack.info version.code must be a positive integer")
if not isinstance(version.get("name"), str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", version["name"]):
    fail("pack.info version.name must be one to three dot-separated integers")

module_app = module.get("app", {})
if module_app.get("bundleName") != expected_bundle:
    fail(f"module.json app.bundleName must be {expected_bundle}")
if module_app.get("vendor") != expected_vendor:
    fail(f"module.json app.vendor must be {expected_vendor}")
if module_app.get("bundleType") != "app":
    fail("module.json app.bundleType must be app")

permissions = [
    item.get("name")
    for item in module.get("module", {}).get("requestPermissions", [])
]
expected_permissions = [
    "ohos.permission.INTERNET",
    "ohos.permission.ACCESS_BIOMETRIC",
]
if permissions != expected_permissions:
    fail(f"module.json permissions must be {expected_permissions}, got {permissions}")

print(f"bundleName={expected_bundle}")
print(f"vendor={expected_vendor}")
print(f"version={version['name']}({version['code']})")
print("permissions=" + ",".join(permissions))
PY

ok "HAP metadata matches production contract"

SIGN_TOOL="${HARMONY_HAP_SIGN_TOOL:-$HARMONY_COMMAND_LINK_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar}"
if [[ "$EXPECTED_SIGNATURE" == "any" && ! -f "$SIGN_TOOL" ]]; then
  echo "[WARN] hap-sign-tool not found; skipping optional signature check: $SIGN_TOOL"
  exit 0
fi
[[ -f "$SIGN_TOOL" ]] || fail "hap-sign-tool not found: $SIGN_TOOL"

SIGNATURE_LOG="$VERIFY_TMP/verify-app.log"
set +e
java -jar "$SIGN_TOOL" verify-app \
  -inFile "$HAP_PATH" \
  -outCertChain "$VERIFY_TMP/cert-chain.cer" \
  -outProfile "$VERIFY_TMP/profile.p7b" \
  >"$SIGNATURE_LOG" 2>&1
SIGNATURE_STATUS=$?
set -e

if [[ $SIGNATURE_STATUS -eq 0 ]]; then
  ok "HAP signature verified"
  if [[ "$EXPECTED_SIGNATURE" == "unsigned" ]]; then
    fail "Expected an unsigned HAP, but signature verification succeeded"
  fi
else
  if [[ "$EXPECTED_SIGNATURE" == "signed" ]]; then
    sed -n '1,80p' "$SIGNATURE_LOG" >&2
    fail "Expected a signed HAP, but signature verification failed"
  fi
  ok "HAP signature is absent or unverifiable as expected"
fi
