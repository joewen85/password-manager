#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${1:-$ROOT_DIR/build/Release-iphonesimulator/PasswordManageriOS.app}"
BUNDLE_ID="${IOS_BUNDLE_ID:-life.devops.passwordmanager}"
SMOKE_DIR="${IOS_SIMULATOR_SMOKE_DIR:-$ROOT_DIR/build/simulator-smoke}"
SCREENSHOT="$SMOKE_DIR/launch.png"
LAUNCH_STDOUT="$SMOKE_DIR/launch.stdout"
LAUNCH_STDERR="$SMOKE_DIR/launch.stderr"
SIM_UDID="${IOS_SIMULATOR_UDID:-}"
CREATED_SIMULATOR=false

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

cleanup() {
  if [[ "$CREATED_SIMULATOR" == "true" && -n "${SIM_UDID:-}" ]]; then
    xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIM_UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

require_command xcrun
require_command python3
require_command file

[[ -d "$APP_BUNDLE" ]] || fail "Missing app bundle: $APP_BUNDLE"
[[ -f "$APP_BUNDLE/Info.plist" ]] || fail "Missing Info.plist in app bundle: $APP_BUNDLE"

actual_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Info.plist" 2>/dev/null || true)"
[[ "$actual_bundle_id" == "$BUNDLE_ID" ]] || fail "Expected bundle id $BUNDLE_ID but found $actual_bundle_id"

select_simulator_target() {
  python3 - <<'PY'
import json
import re
import subprocess
import sys


def load_json(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *args], text=True))


def is_available(runtime):
    if "isAvailable" in runtime:
        return bool(runtime["isAvailable"])
    return runtime.get("availability") == "(available)"


def version_key(runtime):
    version = runtime.get("version", "")
    numbers = [int(part) for part in re.findall(r"\d+", version)]
    return numbers or [0]


runtimes = [
    runtime
    for runtime in load_json("runtimes").get("runtimes", [])
    if runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS")
    and is_available(runtime)
]
if not runtimes:
    sys.exit("No available iOS simulator runtime found")
runtime = sorted(runtimes, key=version_key, reverse=True)[0]

device_types = [
    device_type
    for device_type in load_json("devicetypes").get("devicetypes", [])
    if device_type.get("name", "").startswith("iPhone ")
]
if not device_types:
    sys.exit("No iPhone simulator device type found")

preferred_names = [
    "iPhone 17",
    "iPhone 17 Pro",
    "iPhone 16",
    "iPhone 16 Pro",
    "iPhone 15",
    "iPhone 15 Pro",
    "iPhone 14",
    "iPhone 14 Pro",
]
by_name = {device_type["name"]: device_type for device_type in device_types}
device_type = next((by_name[name] for name in preferred_names if name in by_name), device_types[0])
print(runtime["identifier"], device_type["identifier"])
PY
}

if [[ -z "$SIM_UDID" ]]; then
  read -r simulator_runtime simulator_device_type < <(select_simulator_target)
  sim_name="PasswordManageriOSSmoke-$$-$(date +%s)"
  SIM_UDID="$(xcrun simctl create "$sim_name" "$simulator_device_type" "$simulator_runtime")"
  CREATED_SIMULATOR=true
  ok "Created temporary iOS simulator $SIM_UDID"
else
  ok "Using iOS simulator $SIM_UDID"
fi

xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
ok "iOS simulator is booted"

mkdir -p "$SMOKE_DIR"
rm -f "$SCREENSHOT"

xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_UDID" "$APP_BUNDLE"
app_container="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" app)"
[[ -d "$app_container" ]] || fail "Installed app container was not found"
ok "Installed $BUNDLE_ID into simulator"

xcrun simctl appinfo "$SIM_UDID" "$BUNDLE_ID" >/dev/null
ok "simctl appinfo confirms the app is installed"

print_launch_artifacts() {
  printf 'Launch stdout: %s\n' "$LAUNCH_STDOUT" >&2
  printf 'Launch stderr: %s\n' "$LAUNCH_STDERR" >&2
  printf 'Launch screenshot: %s\n' "$SCREENSHOT" >&2
}

rm -f "$LAUNCH_STDOUT" "$LAUNCH_STDERR"
launch_output="$(
  xcrun simctl launch \
    --terminate-running-process \
    --stdout="$LAUNCH_STDOUT" \
    --stderr="$LAUNCH_STDERR" \
    "$SIM_UDID" \
    "$BUNDLE_ID" 2>&1
)" || {
  print_launch_artifacts
  fail "Failed to launch $BUNDLE_ID: $launch_output"
}
printf '%s\n' "$launch_output"
app_pid="$(printf '%s\n' "$launch_output" | awk -F': ' -v bundle="$BUNDLE_ID" '$1 == bundle { print $2; exit }')"
[[ "$app_pid" =~ ^[0-9]+$ ]] || {
  print_launch_artifacts
  fail "Unable to read launched app pid from simctl output: $launch_output"
}
sleep 2
if ps -p "$app_pid" >/dev/null 2>&1; then
  ok "Launched app process is visible on the host"
else
  warn "Host ps could not observe PID $app_pid; continuing because simctl launch and screenshot succeeded"
fi

if [[ -s "$LAUNCH_STDOUT" ]]; then
  ok "Captured app stdout at $LAUNCH_STDOUT"
fi
if [[ -s "$LAUNCH_STDERR" ]]; then
  warn "Captured app stderr at $LAUNCH_STDERR"
fi

xcrun simctl io "$SIM_UDID" screenshot "$SCREENSHOT" >/dev/null
[[ -s "$SCREENSHOT" ]] || fail "Simulator launch screenshot was not written"
file "$SCREENSHOT" | grep -q "PNG image data" || fail "Simulator launch screenshot is not a PNG"
ok "Captured simulator launch screenshot at $SCREENSHOT"
