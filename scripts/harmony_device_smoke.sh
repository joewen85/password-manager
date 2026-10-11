#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/harmony_app"
DEFAULT_HAP_PATH="$APP_DIR/entry/build/default/outputs/default/entry-default-signed.hap"
HAP_PATH="${1:-$DEFAULT_HAP_PATH}"
BUNDLE_NAME="${2:-life.devops.passwordmanager}"
SMOKE_DIR="${HARMONY_SMOKE_DIR:-$APP_DIR/entry/build/device-smoke}"
TARGET="${HARMONY_TARGET:-}"
TIMEOUT_SECONDS="${HARMONY_SMOKE_TIMEOUT_SECONDS:-45}"
INSTALLED=false

source "$ROOT_DIR/scripts/harmony_env.sh"

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

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

require_command hdc
require_command python3

if [[ ! -f "$HAP_PATH" ]]; then
  fail "HAP file does not exist: $HAP_PATH"
fi

case "$BUNDLE_NAME" in
  *[!a-z0-9+.-]*|'') fail "Invalid Harmony bundle name: $BUNDLE_NAME" ;;
esac

mkdir -p "$SMOKE_DIR"
INSTALL_LOG="$SMOKE_DIR/install.log"
LAUNCH_LOG="$SMOKE_DIR/launch.log"
HILOG_LOG="$SMOKE_DIR/hilog.log"
UNINSTALL_LOG="$SMOKE_DIR/uninstall.log"

cleanup() {
  if [[ "$INSTALLED" == "true" ]]; then
    hdc -t "$TARGET" uninstall "$BUNDLE_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

targets="$(hdc list targets | tr -d '\r' | sed '/^[[:space:]]*$/d' | sed '/^\[Empty\]$/d')"
if [[ -z "${targets//[[:space:]]/}" ]]; then
  fail "No connected Harmony devices detected by hdc"
fi

if [[ -z "$TARGET" ]]; then
  TARGET="$(printf '%s\n' "$targets" | awk 'NR==1 { print $1 }')"
fi

if [[ -z "$TARGET" ]]; then
  fail "Unable to select a Harmony target from hdc list targets"
fi

ok "Using Harmony target $TARGET"
printf '[INFO] Installing %s\n' "$HAP_PATH"
if ! hdc -t "$TARGET" install -r "$HAP_PATH" >"$INSTALL_LOG" 2>&1; then
  sed -n '1,120p' "$INSTALL_LOG" >&2 || true
  fail "Harmony HAP installation failed"
fi
INSTALLED=true

python3 - "$TARGET" "$BUNDLE_NAME" "$TIMEOUT_SECONDS" "$LAUNCH_LOG" "$HILOG_LOG" <<'PY'
from __future__ import annotations

import pathlib
import selectors
import subprocess
import sys
import time

target = sys.argv[1]
bundle = sys.argv[2]
timeout_seconds = int(sys.argv[3])
launch_log_path = pathlib.Path(sys.argv[4])
hilog_log_path = pathlib.Path(sys.argv[5])

required_signals = {
    "on_create": False,
    "loaded": False,
}

def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] {message}")

def ok(message: str) -> None:
    print(f"[OK] {message}")

hilog = subprocess.Popen(
    ["hdc", "-t", target, "shell", "hilog"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
)
assert hilog.stdout is not None
selector = selectors.DefaultSelector()
selector.register(hilog.stdout, selectors.EVENT_READ)

try:
    launch = subprocess.run(
        ["hdc", "-t", target, "shell", "aa", "start", "-b", bundle],
        capture_output=True,
        text=True,
    )
    launch_log_path.write_text((launch.stdout or "") + (launch.stderr or ""), encoding="utf-8")
    if launch.returncode != 0:
      if launch.stdout:
        print(launch.stdout, end="")
      if launch.stderr:
        print(launch.stderr, end="", file=sys.stderr)
      fail(f"aa start failed for {bundle}")
    if launch.stdout:
      print(launch.stdout, end="")
    if launch.stderr:
      print(launch.stderr, end="", file=sys.stderr)

    deadline = time.time() + timeout_seconds
    while time.time() < deadline and not required_signals["loaded"]:
        events = selector.select(timeout=1)
        for key, _ in events:
            line = key.fileobj.readline()
            if not line:
                continue
            with hilog_log_path.open("a", encoding="utf-8") as handle:
                handle.write(line)
            if "PasswordManager EntryAbility onCreate" in line:
                required_signals["on_create"] = True
            if "Succeeded in loading the content." in line:
                required_signals["loaded"] = True
            if "PasswordManager EntryAbility onForeground" in line:
                required_signals["on_foreground"] = True
        if required_signals["loaded"]:
            break
    if not required_signals["on_create"]:
        fail("Did not observe EntryAbility onCreate in hilog")
    if not required_signals["loaded"]:
        fail(
            "Did not observe launch success logs from EntryAbility "
            "within the timeout window"
        )
    ok("Harmony launch smoke observed EntryAbility startup logs")
finally:
    selector.close()
    hilog.terminate()
    try:
        hilog.wait(timeout=5)
    except subprocess.TimeoutExpired:
        hilog.kill()
        hilog.wait(timeout=5)
PY

printf '[INFO] Uninstalling %s\n' "$BUNDLE_NAME"
if ! hdc -t "$TARGET" uninstall "$BUNDLE_NAME" >"$UNINSTALL_LOG" 2>&1; then
  sed -n '1,120p' "$UNINSTALL_LOG" >&2 || true
  fail "Harmony HAP uninstall failed"
fi

ok "Harmony install/launch smoke completed"
