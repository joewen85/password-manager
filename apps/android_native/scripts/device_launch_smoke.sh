#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$APP_ROOT"

ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
SERIAL="${ANDROID_SERIAL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-life.devops.passwordmanager}"
ACTIVITY_NAME="${ACTIVITY_NAME:-life.devops.passwordmanager.MainActivity}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$APP_ROOT/build/device-smoke}"
UI_XML="$ARTIFACT_DIR/ui.xml"
SCREENSHOT="$ARTIFACT_DIR/launch.png"
CRASH_LOG="$ARTIFACT_DIR/crash-logcat.txt"
RESET_APP_DATA="${RESET_APP_DATA:-true}"

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

echo "Running Android device launch smoke on $SERIAL..."
./gradlew :app:installDebug

ACTIVITY="$("$ADB" -s "$SERIAL" shell cmd package resolve-activity --brief "$PACKAGE_NAME" | tail -n 1 | tr -d '\r')"
SHORT_ACTIVITY_NAME=".${ACTIVITY_NAME##*.}"
if [[ "$ACTIVITY" != "$PACKAGE_NAME/$ACTIVITY_NAME" && "$ACTIVITY" != "$PACKAGE_NAME/$SHORT_ACTIVITY_NAME" ]]; then
  echo "Unexpected launcher activity: $ACTIVITY" >&2
  exit 1
fi

"$ADB" -s "$SERIAL" logcat -c
if [[ "$RESET_APP_DATA" == "true" ]]; then
  "$ADB" -s "$SERIAL" shell pm clear "$PACKAGE_NAME" >/dev/null
fi
"$ADB" -s "$SERIAL" shell am force-stop com.android.vending >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" shell am force-stop "$PACKAGE_NAME"
"$ADB" -s "$SERIAL" shell am start -W -n "$PACKAGE_NAME/$ACTIVITY_NAME" >/dev/null
sleep 3

PID="$("$ADB" -s "$SERIAL" shell pidof -s "$PACKAGE_NAME" | tr -d '\r' || true)"
if [[ -z "$PID" ]]; then
  "$ADB" -s "$SERIAL" logcat -d > "$ARTIFACT_DIR/logcat.txt"
  echo "App process is not running after launch. Logcat saved to $ARTIFACT_DIR/logcat.txt" >&2
  exit 1
fi

"$ADB" -s "$SERIAL" exec-out uiautomator dump /dev/tty > "$UI_XML"
"$ADB" -s "$SERIAL" exec-out screencap -p > "$SCREENSHOT"
"$ADB" -s "$SERIAL" logcat -d -b crash > "$CRASH_LOG"

python3 - "$UI_XML" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
raw = path.read_text(errors="replace")
if raw.startswith("UI hierchary dumped to:"):
    raw = raw.split("\n", 1)[1]
start = raw.find("<hierarchy")
end = raw.rfind("</hierarchy>")
if start == -1 or end == -1:
    raise SystemExit(f"Could not find hierarchy XML in {path}")
raw = raw[start:end + len("</hierarchy>")]

root = ET.fromstring(raw)
texts = {
    node.attrib.get("text", "")
    for node in root.iter("node")
    if node.attrib.get("text")
}
required = {
    "Initialize Vault",
    "Master password",
    "Confirm master password",
    "Create Vault",
}
missing = sorted(required - texts)
if missing:
    raise SystemExit(f"Missing expected first-screen text: {missing}; found={sorted(texts)}")

print("firstScreenTexts=", sorted(required))
PY

if [[ -s "$CRASH_LOG" ]]; then
  echo "Crash buffer is not empty. See $CRASH_LOG" >&2
  exit 1
fi

echo "device=$SERIAL"
echo "launcherActivity=$ACTIVITY"
echo "pid=$PID"
echo "ui=$UI_XML"
echo "screenshot=$SCREENSHOT"
echo "crashLog=$CRASH_LOG"
echo "Android device launch smoke completed."
