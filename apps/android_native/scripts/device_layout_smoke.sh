#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$APP_ROOT"

ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
SERIAL="${ANDROID_SERIAL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-life.devops.passwordmanager}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$APP_ROOT/build/device-layout-smoke}"
MASTER_PASSWORD="${MASTER_PASSWORD:-SmokePass123}"

if [[ ! -x "$ADB" ]]; then
  echo "adb not found or not executable: $ADB" >&2
  echo "Set ANDROID_HOME or ADB=/absolute/path/to/adb." >&2
  exit 1
fi

if [[ -z "$SERIAL" ]]; then
  DEVICES="$("$ADB" devices | awk 'NR > 1 && $2 == "device" {print $1}')"
  DEVICE_COUNT="$(printf '%s\n' "$DEVICES" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  if [[ "$DEVICE_COUNT" != "1" ]]; then
    echo "Expected exactly one connected adb device, found $DEVICE_COUNT." >&2
    printf 'Devices:\n%s\n' "${DEVICES:-<none>}" >&2
    echo "Set ANDROID_SERIAL=<serial> to choose a device." >&2
    exit 1
  fi
  SERIAL="$DEVICES"
fi

mkdir -p "$ARTIFACT_DIR"

cleanup() {
  "$ADB" -s "$SERIAL" shell wm size reset >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell wm density reset >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell am force-stop "$PACKAGE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

dump_ui() {
  local output="$1"
  "$ADB" -s "$SERIAL" exec-out uiautomator dump /dev/tty > "$output"
}

center_for_text() {
  local ui_xml="$1"
  local target="$2"
  python3 - "$ui_xml" "$target" "$PACKAGE_NAME" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
target_package = sys.argv[3]
raw = path.read_text(errors="replace")
start = raw.find("<hierarchy")
end = raw.rfind("</hierarchy>")
if start == -1 or end == -1:
    raise SystemExit(f"Could not find hierarchy XML in {path}")

root = ET.fromstring(raw[start:end + len("</hierarchy>")])
for node in root.iter("node"):
    if node.attrib.get("package", "") != target_package:
        continue
    text = node.attrib.get("text", "")
    if text == target:
        bounds = node.attrib.get("bounds", "")
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
        if not match:
            raise SystemExit(f"Node {target!r} has invalid bounds: {bounds!r}")
        x1, y1, x2, y2 = map(int, match.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        raise SystemExit(0)

available = sorted(
    node.attrib.get("text", "")
    for node in root.iter("node")
    if node.attrib.get("text") and node.attrib.get("package", "") == target_package
)
raise SystemExit(f"Could not find text {target!r}; available={available}")
PY
}

center_for_description() {
  local ui_xml="$1"
  local target="$2"
  python3 - "$ui_xml" "$target" "$PACKAGE_NAME" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
target_package = sys.argv[3]
raw = path.read_text(errors="replace")
start = raw.find("<hierarchy")
end = raw.rfind("</hierarchy>")
if start == -1 or end == -1:
    raise SystemExit(f"Could not find hierarchy XML in {path}")

root = ET.fromstring(raw[start:end + len("</hierarchy>")])
for node in root.iter("node"):
    if node.attrib.get("package", "") != target_package:
        continue
    desc = node.attrib.get("content-desc", "")
    if desc == target:
        bounds = node.attrib.get("bounds", "")
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
        if not match:
            raise SystemExit(f"Node {target!r} has invalid bounds: {bounds!r}")
        x1, y1, x2, y2 = map(int, match.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        raise SystemExit(0)

available = sorted(
    node.attrib.get("content-desc", "")
    for node in root.iter("node")
    if node.attrib.get("content-desc") and node.attrib.get("package", "") == target_package
)
raise SystemExit(f"Could not find content-desc {target!r}; available={available}")
PY
}

tap_text() {
  local target="$1"
  local ui_xml="$2"
  read -r x y < <(center_for_text "$ui_xml" "$target")
  "$ADB" -s "$SERIAL" shell input tap "$x" "$y"
}

tap_description() {
  local target="$1"
  local ui_xml="$2"
  read -r x y < <(center_for_description "$ui_xml" "$target")
  "$ADB" -s "$SERIAL" shell input tap "$x" "$y"
}

wait_for_text() {
  local target="$1"
  local ui_xml="$2"
  for _ in {1..20}; do
    dump_ui "$ui_xml"
    if python3 - "$ui_xml" "$target" "$PACKAGE_NAME" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
target_package = sys.argv[3]
raw = path.read_text(errors="replace")
start = raw.find("<hierarchy")
end = raw.rfind("</hierarchy>")
if start == -1 or end == -1:
    raise SystemExit(1)

root = ET.fromstring(raw[start:end + len("</hierarchy>")])
texts = {
    node.attrib.get("text", "")
    for node in root.iter("node")
    if node.attrib.get("text") and node.attrib.get("package", "") == target_package
}
descs = {
    node.attrib.get("content-desc", "")
    for node in root.iter("node")
    if node.attrib.get("content-desc") and node.attrib.get("package", "") == target_package
}
packages = {node.attrib.get("package", "") for node in root.iter("node")}
raise SystemExit(0 if (target in texts or target in descs) and target_package in packages else 1)
PY
    then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for UI text: $target" >&2
  return 1
}

assert_profile_ui() {
  local profile="$1"
  local ui_xml="$2"
  local expect_expanded="$3"
  python3 - "$profile" "$ui_xml" "$expect_expanded" "$PACKAGE_NAME" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

profile = sys.argv[1]
path = Path(sys.argv[2])
expect_expanded = sys.argv[3] == "true"
target_package = sys.argv[4]
raw = path.read_text(errors="replace")
start = raw.find("<hierarchy")
end = raw.rfind("</hierarchy>")
if start == -1 or end == -1:
    raise SystemExit(f"Could not find hierarchy XML in {path}")

root = ET.fromstring(raw[start:end + len("</hierarchy>")])
texts = {
    node.attrib.get("text", "")
    for node in root.iter("node")
    if node.attrib.get("text") and node.attrib.get("package", "") == target_package
}
descs = {
    node.attrib.get("content-desc", "")
    for node in root.iter("node")
    if node.attrib.get("content-desc") and node.attrib.get("package", "") == target_package
}
packages = {node.attrib.get("package", "") for node in root.iter("node")}
if target_package not in packages:
    raise SystemExit(f"{profile}: UI tree does not contain package {target_package}; packages={sorted(packages)}")

required_texts = {"Search, e.g. ip:1.2.3.4 name:xxx..."}
required_descs = {"Create", "Sync", "Backups", "More actions", "Lock"}
missing_texts = sorted(required_texts - texts)
missing_descs = sorted(required_descs - descs)
missing = missing_texts + [f"desc:{value}" for value in missing_descs]
if missing:
    raise SystemExit(f"{profile}: missing expected home controls {missing}; texts={sorted(texts)} descs={sorted(descs)}")

has_detail_placeholder = "Select an entry" in texts
if expect_expanded and not has_detail_placeholder:
    raise SystemExit(f"{profile}: expected expanded detail placeholder; found={sorted(texts)}")
if not expect_expanded and has_detail_placeholder:
    raise SystemExit(f"{profile}: compact layout unexpectedly rendered the detail pane")

print(f"{profile}Texts=", sorted(required_texts | ({"Select an entry"} if expect_expanded else set())))
PY
}

run_profile() {
  local profile="$1"
  local size="$2"
  local density="$3"
  local expect_expanded="$4"
  local profile_dir="$ARTIFACT_DIR/$profile"
  local init_ui="$profile_dir/initialize.xml"
  local home_ui="$profile_dir/home.xml"
  local screenshot="$profile_dir/home.png"
  local crash_log="$profile_dir/crash-logcat.txt"
  local app_crash_log="$profile_dir/app-crash-logcat.txt"

  mkdir -p "$profile_dir"

  echo "Running $profile layout smoke: size=$size density=$density expanded=$expect_expanded"
  "$ADB" -s "$SERIAL" shell wm size "$size" >/dev/null
  "$ADB" -s "$SERIAL" shell wm density "$density" >/dev/null
  sleep 1

  "$ADB" -s "$SERIAL" shell pm clear "$PACKAGE_NAME" >/dev/null
  "$ADB" -s "$SERIAL" logcat -c
  "$ADB" -s "$SERIAL" shell am force-stop com.android.vending >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell am force-stop "$PACKAGE_NAME" >/dev/null
  "$ADB" -s "$SERIAL" shell am start -W -n "$PACKAGE_NAME/.MainActivity" >/dev/null

  wait_for_text "Initialize Vault" "$init_ui"
  tap_text "Master password" "$init_ui"
  "$ADB" -s "$SERIAL" shell input text "$MASTER_PASSWORD"
  dump_ui "$init_ui"
  tap_text "Confirm master password" "$init_ui"
  "$ADB" -s "$SERIAL" shell input text "$MASTER_PASSWORD"
  dump_ui "$init_ui"
  tap_text "Create Vault" "$init_ui"

  wait_for_text "Search, e.g. ip:1.2.3.4 name:xxx..." "$home_ui"
  "$ADB" -s "$SERIAL" exec-out screencap -p > "$screenshot"
  "$ADB" -s "$SERIAL" logcat -d -b crash > "$crash_log"
  grep -F "$PACKAGE_NAME" "$crash_log" > "$app_crash_log" || true
  assert_profile_ui "$profile" "$home_ui" "$expect_expanded"

  if [[ -s "$app_crash_log" ]]; then
    echo "$profile app crash buffer is not empty. See $app_crash_log" >&2
    exit 1
  fi

  echo "$profile.ui=$home_ui"
  echo "$profile.screenshot=$screenshot"
  echo "$profile.crashLog=$crash_log"
  echo "$profile.appCrashLog=$app_crash_log"
}

echo "Running Android device layout smoke on $SERIAL..."
./gradlew :app:installDebug

ACTIVITY="$("$ADB" -s "$SERIAL" shell cmd package resolve-activity --brief "$PACKAGE_NAME" | tail -n 1 | tr -d '\r')"
if [[ "$ACTIVITY" != "$PACKAGE_NAME/.MainActivity" ]]; then
  echo "Unexpected launcher activity: $ACTIVITY" >&2
  exit 1
fi

run_profile "compact" "1080x2400" "420" "false"
run_profile "expanded" "1920x1200" "160" "true"

echo "device=$SERIAL"
echo "launcherActivity=$ACTIVITY"
echo "artifacts=$ARTIFACT_DIR"
echo "Android device layout smoke completed."
