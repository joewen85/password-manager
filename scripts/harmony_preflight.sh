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

if node "$ROOT_DIR/scripts/harmony_category_sync_tests.mjs"; then
  ok "Harmony category sync regression tests passed"
else
  fail "Harmony category sync regression tests failed"
  status=1
fi

if node "$ROOT_DIR/scripts/harmony_reference_resolver_tests.mjs"; then
  ok "Harmony entry-reference resolver tests passed"
else
  fail "Harmony entry-reference resolver tests failed"
  status=1
fi

if node "$ROOT_DIR/scripts/harmony_reference_operations_tests.mjs"; then
  ok "Harmony entry-reference operation tests passed"
else
  fail "Harmony entry-reference operation tests failed"
  status=1
fi

if node "$ROOT_DIR/scripts/harmony_field_reference_ui_tests.mjs"; then
  ok "Harmony field-reference UI tests passed"
else
  fail "Harmony field-reference UI tests failed"
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
  ok "Harmony bundleName matches Android production applicationId and contains no hyphen: $EXPECTED_BUNDLE_NAME"
else
  fail "Harmony bundleName must be $EXPECTED_BUNDLE_NAME, not an example or hyphenated identifier"
  status=1
fi

if grep -Eq "\"vendor\"[[:space:]]*:[[:space:]]*\"$EXPECTED_VENDOR\"" "$app_scope_file"; then
  ok "Harmony vendor is production metadata: $EXPECTED_VENDOR"
else
  fail "Harmony vendor must be production metadata, not an example value"
  status=1
fi

if grep -R -En "快捷操作|ActionPanel|SettingsPage|showQuickActions|showSettingsPage" \
  "$APP_DIR/entry/src/main/ets" >/tmp/harmony_old_ui_markers.txt 2>/dev/null; then
  fail "Harmony source still contains old top-bar/settings UI markers"
  sed 's/^/[INFO] /' /tmp/harmony_old_ui_markers.txt
  status=1
else
  ok "Harmony source no longer contains old top-bar/settings UI markers"
fi

check_cached_bundle_name() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    warn "$label not found; DevEco may recreate it on next sync"
    return
  fi

  if grep -q "com.example.passwordmanager" "$file"; then
    fail "$label still references old bundleName com.example.passwordmanager"
    status=1
    return
  fi

  if grep -Eq "\"BUNDLE_NAME\"[[:space:]]*:[[:space:]]*\"$EXPECTED_BUNDLE_NAME\"" "$file"; then
    ok "$label bundleName cache matches: $EXPECTED_BUNDLE_NAME"
  elif grep -q "\"BUNDLE_NAME\"" "$file"; then
    fail "$label has a BUNDLE_NAME that does not match $EXPECTED_BUNDLE_NAME"
    status=1
  else
    warn "$label has no BUNDLE_NAME entry"
  fi
}

check_cached_bundle_name "$APP_DIR/.idea/.deveco/project.cache.json" "DevEco project cache"
check_cached_bundle_name "$APP_DIR/.hvigor/outputs/sync/output.json" "Hvigor sync cache"

workspace_file="$APP_DIR/.idea/workspace.xml"
if [[ -f "$workspace_file" ]]; then
  selected_run_config="$(grep -Eo '<component name="RunManager" selected="[^"]+"' "$workspace_file" \
    | sed -E 's/.*selected="([^"]+)"/\1/' \
    | head -n 1 || true)"
  if [[ "$selected_run_config" == *"Hot Reload"* ]]; then
    fail "DevEco selected run configuration is Hot Reload; choose Application.entry / OpenHarmony App.entry"
    status=1
  elif [[ -n "$selected_run_config" ]]; then
    ok "DevEco selected run configuration: $selected_run_config"
  else
    warn "DevEco selected run configuration not found in workspace.xml"
  fi

  if grep -q 'type="HotReLoadTask"' "$workspace_file"; then
    warn "Hot Reload run configuration still exists; avoid it when validating full UI changes"
  fi
else
  warn "DevEco workspace.xml not found; open apps/harmony_app in DevEco and sync the project"
fi

existing_hap="$(find "$APP_DIR/entry/build" -type f -name "*.hap" 2>/dev/null | head -n 1 || true)"
if [[ -n "$existing_hap" ]]; then
  if EXPECTED_SIGNATURE="${HARMONY_EXPECT_HAP_SIGNATURE:-unsigned}" \
    "$ROOT_DIR/scripts/harmony_verify_hap.sh" "$existing_hap"; then
    ok "Existing HAP metadata is current: $(relative_path "$existing_hap")"
  else
    fail "Existing HAP metadata is stale or invalid: $(relative_path "$existing_hap")"
    status=1
  fi
else
  warn "No existing HAP found under entry/build; run scripts/harmony_build_hap.sh default before device testing"
fi

if find "$APP_DIR" -maxdepth 1 -type d -name ".codex-cache-backup-*" | grep -q .; then
  warn "Old Codex cache backup directory exists inside harmony_app; move it out before DevEco validation"
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
