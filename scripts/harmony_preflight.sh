#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/harmony_app"
EXPECTED_BUNDLE_NAME="life.devops.passwordmanager"
EXPECTED_VENDOR="DevOps Life"
source "$ROOT_DIR/scripts/harmony_env.sh"

ok() { printf "[OK] %s\n" "$1"; }
warn() { printf "[WARN] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; }

status=0

echo "== HarmonyOS DevEco Preflight =="
echo "Project: $APP_DIR"

relative_path() {
  local path="$1"
  if [[ "$path" == "$ROOT_DIR/"* ]]; then
    printf "%s" "${path#"$ROOT_DIR/"}"
    return
  fi
  printf "%s" "$path"
}

if [[ -d "$APP_DIR" ]]; then
  ok "harmony_app directory exists"
else
  fail "harmony_app directory missing"
  exit 1
fi

required_files=(
  "$APP_DIR/AppScope/app.json5"
  "$APP_DIR/build-profile.json5"
  "$APP_DIR/hvigor/hvigor-config.json5"
  "$APP_DIR/entry/src/main/module.json5"
  "$APP_DIR/entry/src/main/ets/entryability/EntryAbility.ets"
  "$APP_DIR/entry/src/main/ets/pages/Index.ets"
)

for file in "${required_files[@]}"; do
  if [[ -f "$file" ]]; then
    ok "found $(relative_path "$file")"
  else
    fail "missing $(relative_path "$file")"
    status=1
  fi
done

if node "$ROOT_DIR/scripts/harmony_contract_tests.mjs"; then
  ok "Harmony contract tests passed"
else
  fail "Harmony contract tests failed"
  status=1
fi

crypto_file="$APP_DIR/entry/src/main/ets/src/security/VaultCryptoService.ets"
if grep -Eq "DEFAULT_ITERATIONS:[[:space:]]*number[[:space:]]*=[[:space:]]*600000;" "$crypto_file"; then
  ok "Harmony PBKDF2 default matches Dart/Android/macOS/iOS contract: 600000 iterations"
else
  fail "Harmony PBKDF2 default must be 600000 iterations for new vaults"
  status=1
fi

app_scope_file="$APP_DIR/AppScope/app.json5"
if grep -Eq "\"bundleName\"[[:space:]]*:[[:space:]]*\"$EXPECTED_BUNDLE_NAME\"" "$app_scope_file"; then
  ok "Harmony bundleName matches Android production applicationId: $EXPECTED_BUNDLE_NAME"
else
  fail "Harmony bundleName must be $EXPECTED_BUNDLE_NAME, not an example identifier"
  status=1
fi

if grep -Eq "\"vendor\"[[:space:]]*:[[:space:]]*\"$EXPECTED_VENDOR\"" "$app_scope_file"; then
  ok "Harmony vendor is production metadata: $EXPECTED_VENDOR"
else
  fail "Harmony vendor must be production metadata, not an example value"
  status=1
fi

check_cmd() {
  local cmd="$1"
  local name="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$name detected: $(command -v "$cmd")"
  else
    warn "$name not found in PATH"
  fi
}

check_cmd java "Java"
check_cmd node "Node.js"
check_cmd hvigorw "Hvigor Wrapper"
check_cmd ohpm "OHPM"
check_cmd hdc "Harmony Device Connector (hdc)"

if command -v java >/dev/null 2>&1; then
  if java -version >/tmp/harmony_java.txt 2>&1; then
    head -n 2 /tmp/harmony_java.txt | sed 's/^/[INFO] /'
  else
    warn "java command exists but runtime is not ready"
    head -n 2 /tmp/harmony_java.txt | sed 's/^/[INFO] /'
  fi
fi

if command -v node >/dev/null 2>&1; then
  node -v | sed 's/^/[INFO] Node version: /'
fi

if command -v hvigorw >/dev/null 2>&1; then
  hvigorw -v | sed 's/^/[INFO] Hvigor version: /'
fi

if [[ -n "${JAVA_HOME:-}" ]]; then
  ok "JAVA_HOME detected: $JAVA_HOME"
fi

if command -v hdc >/dev/null 2>&1; then
  if hdc list targets >/tmp/harmony_targets.txt 2>/tmp/harmony_targets_err.txt; then
    targets="$(cat /tmp/harmony_targets.txt)"
    normalized_targets="$(printf '%s' "$targets" | tr -d '\r' | sed '/^[[:space:]]*$/d' | sed '/^\[Empty\]$/d')"
    if [[ -z "${normalized_targets//[[:space:]]/}" ]]; then
      warn "No connected Harmony devices detected by hdc"
    else
      ok "Connected Harmony devices:"
      sed 's/^/[INFO]   /' /tmp/harmony_targets.txt
    fi
  else
    warn "hdc command exists but list targets failed"
    sed 's/^/[INFO] /' /tmp/harmony_targets_err.txt || true
  fi
fi

echo
if [[ $status -eq 0 ]]; then
  ok "Preflight completed"
else
  fail "Preflight completed with missing required project files"
fi

exit $status
