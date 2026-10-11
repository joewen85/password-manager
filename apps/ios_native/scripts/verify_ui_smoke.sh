#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/PasswordManageriOS.xcodeproj"
SCHEME="${IOS_UI_TEST_SCHEME:-PasswordManageriOS}"
CONFIGURATION="${IOS_UI_TEST_CONFIGURATION:-Release}"
TEST_IDENTIFIER="${IOS_UI_TEST_IDENTIFIER:-PasswordManageriOSUITests/PasswordManageriOSLaunchUITests/testInitialVaultScreenHasRequiredControls}"
SIM_UDID="${IOS_UI_TEST_SIMULATOR_UDID:-}"
CREATED_SIMULATOR=false

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

ok() {
  printf '[OK] %s\n' "$1"
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

require_command xcodebuild
require_command xcrun
require_command python3

[[ -d "$PROJECT" ]] || fail "Missing Xcode project: $PROJECT"

select_simulator_target() {
  python3 - <<'PY'
import json
import re
import subprocess
import sys


def load_json(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *args], text=True))


def is_available(item):
    if "isAvailable" in item:
        return bool(item["isAvailable"])
    return item.get("availability") == "(available)"


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
  sim_name="PasswordManageriOSUISmoke-$$-$(date +%s)"
  SIM_UDID="$(xcrun simctl create "$sim_name" "$simulator_device_type" "$simulator_runtime")"
  CREATED_SIMULATOR=true
  ok "Created temporary iOS simulator $SIM_UDID"
else
  ok "Using iOS simulator $SIM_UDID"
fi

xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
ok "iOS simulator is booted"

cd "$ROOT_DIR"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "id=$SIM_UDID" \
  -only-testing:"$TEST_IDENTIFIER" \
  CODE_SIGNING_ALLOWED=NO

ok "iOS launch UI smoke passed"
