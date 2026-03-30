#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/harmony_env.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-hap> [bundle-name]"
  echo "Example: $0 apps/harmony_app/entry/build/default/outputs/default/entry-default-signed.hap com.example.passwordmanager"
  exit 1
fi

HAP_PATH="$1"
BUNDLE_NAME="${2:-com.example.passwordmanager}"

if ! command -v hdc >/dev/null 2>&1; then
  echo "[FAIL] hdc is not available in PATH"
  exit 1
fi

if [[ ! -f "$HAP_PATH" ]]; then
  echo "[FAIL] HAP file does not exist: $HAP_PATH"
  exit 1
fi

echo "== HarmonyOS Install HAP =="
targets="$(hdc list targets | tr -d '\r' | sed '/^[[:space:]]*$/d' | sed '/^\[Empty\]$/d')"
if [[ -z "${targets//[[:space:]]/}" ]]; then
  echo "[FAIL] No connected Harmony devices detected by hdc"
  exit 1
fi

echo "$targets"

echo "[INFO] Installing $HAP_PATH"
hdc install -r "$HAP_PATH"

echo "[INFO] Installed bundle: $BUNDLE_NAME"
echo "[INFO] Launch from device launcher, or run manually if your device supports:"
echo "       hdc shell aa start -b $BUNDLE_NAME"
