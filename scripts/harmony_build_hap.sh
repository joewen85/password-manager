#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/harmony_app"
PRODUCT="${1:-default}"
EXPECTED_BUNDLE_NAME="life.devops.passwordmanager"
EXPECTED_VENDOR="DevOps Life"

source "$ROOT_DIR/scripts/harmony_env.sh"

if [[ ! -d "$APP_DIR" ]]; then
  echo "[FAIL] Missing app dir: $APP_DIR"
  exit 1
fi

if [[ ! -f "$APP_DIR/hvigor/hvigor-config.json5" ]]; then
  echo "[FAIL] Missing hvigor config: $APP_DIR/hvigor/hvigor-config.json5"
  exit 1
fi

if ! command -v hvigorw >/dev/null 2>&1; then
  echo "[FAIL] hvigorw not found"
  exit 1
fi

echo "== HarmonyOS Build HAP =="
echo "[INFO] APP_DIR=$APP_DIR"
echo "[INFO] product=$PRODUCT"
echo "[INFO] hvigorw=$(command -v hvigorw)"
if command -v java >/dev/null 2>&1; then
  echo "[INFO] java=$(command -v java)"
fi
if command -v node >/dev/null 2>&1; then
  echo "[INFO] node=$(command -v node)"
fi

echo "[INFO] Running Harmony contract tests..."
node "$ROOT_DIR/scripts/harmony_contract_tests.mjs"

cd "$APP_DIR"

echo "[INFO] Listing available tasks..."
hvigorw tasks -m module -p product="$PRODUCT" >/tmp/harmony_tasks.txt
head -n 40 /tmp/harmony_tasks.txt | sed 's/^/[TASK] /'

echo "[INFO] Running assembleHap..."
hvigorw assembleHap -m module -p product="$PRODUCT" --no-daemon

echo "[INFO] Build outputs (if present):"
find "$APP_DIR/entry/build" -type f \( -name "*.hap" -o -name "*.app" \) 2>/dev/null | sed 's/^/[OUT] /' || true

hap_path="$(find "$APP_DIR/entry/build" -type f -name "*.hap" 2>/dev/null | head -n 1 || true)"
if [[ -z "$hap_path" ]]; then
  echo "[FAIL] No HAP artifact found under $APP_DIR/entry/build"
  exit 1
fi

if unzip -p "$hap_path" pack.info | grep -q "\"bundleName\":\"$EXPECTED_BUNDLE_NAME\""; then
  echo "[OK] HAP pack.info bundleName=$EXPECTED_BUNDLE_NAME"
else
  echo "[FAIL] HAP pack.info must contain bundleName=$EXPECTED_BUNDLE_NAME"
  exit 1
fi

if unzip -p "$hap_path" module.json | grep -q "\"vendor\":\"$EXPECTED_VENDOR\""; then
  echo "[OK] HAP module.json vendor=$EXPECTED_VENDOR"
else
  echo "[FAIL] HAP module.json must contain vendor=$EXPECTED_VENDOR"
  exit 1
fi

echo "[OK] Build command finished"
