#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$APP_ROOT"

if [[ -z "${JAVA_HOME:-}" && -d "/Users/joe/Tools/jdk21/zulu-21.jdk/Contents/Home" ]]; then
  export JAVA_HOME="/Users/joe/Tools/jdk21/zulu-21.jdk/Contents/Home"
fi

JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/java}"
JAVA_BIN="${JAVA_BIN:-java}"
JAVA_VERSION_OUTPUT="$("$JAVA_BIN" -version 2>&1 | head -n 1)"
JAVA_MAJOR="$(printf '%s' "$JAVA_VERSION_OUTPUT" | sed -E 's/.* version "([0-9]+).*/\1/')"
if [[ -z "$JAVA_MAJOR" || "$JAVA_MAJOR" -lt 21 ]]; then
  echo "JDK 21 or newer is required. Current java: $JAVA_VERSION_OUTPUT" >&2
  echo "Set JAVA_HOME=/absolute/path/to/jdk21-or-newer." >&2
  exit 1
fi

echo "Running Android release verification..."
./gradlew --no-daemon -Dkotlin.compiler.execution.strategy=in-process test :app:assembleDebug :app:assembleAndroidTest :app:bundleRelease :app:processReleaseMainManifest --console=plain

MANIFEST="app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml"
AAB="app/build/outputs/bundle/release/app-release.aab"

python3 - <<'PY'
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

manifest_path = Path("app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml")
if not manifest_path.exists():
    raise SystemExit(f"Missing merged release manifest: {manifest_path}")

expected_application_id = "life.devops.passwordmanager"
identifier_pattern = re.compile(r"[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+")

def require_identifier(value, label):
    if not isinstance(value, str) or not value:
        raise SystemExit(f"{label} must be a non-empty string")
    if "-" in value:
        raise SystemExit(f"{label} must not contain '-'")
    if not identifier_pattern.fullmatch(value):
        raise SystemExit(f"{label} must be a dot-separated platform identifier, got {value!r}")

build_gradle = Path("app/build.gradle.kts").read_text(encoding="utf-8")
namespace_match = re.search(r'^\s*namespace\s*=\s*"([^"]+)"', build_gradle, re.MULTILINE)
application_id_match = re.search(r'^\s*applicationId\s*=\s*"([^"]+)"', build_gradle, re.MULTILINE)
if namespace_match is None:
    raise SystemExit("Missing Android namespace in app/build.gradle.kts")
if application_id_match is None:
    raise SystemExit("Missing Android applicationId in app/build.gradle.kts")

namespace = namespace_match.group(1)
application_id = application_id_match.group(1)
require_identifier(namespace, "Android namespace")
require_identifier(application_id, "Android applicationId")
if namespace != expected_application_id:
    raise SystemExit(f"Android namespace must be {expected_application_id}, got {namespace}")
if application_id != expected_application_id:
    raise SystemExit(f"Android applicationId must be {expected_application_id}, got {application_id}")

ns = "{http://schemas.android.com/apk/res/android}"
root = ET.parse(manifest_path).getroot()
permissions = [node.attrib.get(ns + "name") for node in root.findall("uses-permission")]
expected_permissions = [
    "android.permission.INTERNET",
    "android.permission.USE_BIOMETRIC",
    "android.permission.USE_FINGERPRINT",
]
if sorted(permissions) != sorted(expected_permissions):
    raise SystemExit(f"Unexpected permissions: {permissions!r}")

application = root.find("application")
if application is None:
    raise SystemExit("Manifest is missing <application>")

if application.attrib.get(ns + "allowBackup") != "false":
    raise SystemExit("android:allowBackup must remain false")

if application.attrib.get(ns + "icon") != "@mipmap/ic_launcher":
    raise SystemExit("android:icon must reference @mipmap/ic_launcher")

if application.attrib.get(ns + "roundIcon") != "@mipmap/ic_launcher_round":
    raise SystemExit("android:roundIcon must reference @mipmap/ic_launcher_round")

activities = application.findall("activity")
launcher = None
for activity in activities:
    for intent in activity.findall("intent-filter"):
        actions = {node.attrib.get(ns + "name") for node in intent.findall("action")}
        categories = {node.attrib.get(ns + "name") for node in intent.findall("category")}
        if "android.intent.action.MAIN" in actions and "android.intent.category.LAUNCHER" in categories:
            launcher = activity
            break
    if launcher is not None:
        break

if launcher is None:
    raise SystemExit("Missing launcher activity")

if launcher.attrib.get(ns + "exported") != "true":
    raise SystemExit("Launcher activity must remain exported=true")

launcher_name = launcher.attrib.get(ns + "name")
if launcher_name and "-" in launcher_name:
    raise SystemExit("Launcher activity name must not contain '-'")

for icon_path in [
    Path("app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"),
    Path("app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml"),
]:
    icon = ET.parse(icon_path).getroot()
    monochrome = icon.find("monochrome")
    if monochrome is None or monochrome.attrib.get(ns + "drawable") != "@drawable/launcher_monochrome":
        raise SystemExit(f"{icon_path} must include @drawable/launcher_monochrome")

if not Path("app/src/main/res/drawable/launcher_monochrome.xml").exists():
    raise SystemExit("Missing launcher_monochrome.xml")

print("applicationId=", application_id)
print("permissions=", permissions)
print("allowBackup=", application.attrib.get(ns + "allowBackup"))
print("launcherExported=", launcher.attrib.get(ns + "exported"))
print("monochromeIcon= @drawable/launcher_monochrome")
PY

if [[ ! -f "$AAB" ]]; then
  echo "Missing release bundle: $AAB" >&2
  exit 1
fi

echo "Release bundle: $AAB"
ls -lh "$AAB"

SIGNATURE_OUTPUT="$(jarsigner -verify -verbose -certs "$AAB" 2>&1 || true)"
if grep -Eqi "jar is unsigned|jar 未签名|不是已签名" <<<"$SIGNATURE_OUTPUT"; then
  if [[ "${REQUIRE_SIGNED_RELEASE:-false}" == "true" || -n "${EXPECTED_RELEASE_CERT_SHA256:-}" ]]; then
    echo "$SIGNATURE_OUTPUT" >&2
    echo "Release bundle is unsigned, but signed release verification was requested." >&2
    exit 1
  fi
  echo "Release bundle signature: unsigned. This is expected when Play upload key properties are not configured."
elif grep -Eqi "jar verified|jar 已验证|已验证签名" <<<"$SIGNATURE_OUTPUT"; then
  echo "Release bundle signature: cryptographically verified."
  CERT_SHA256="$(keytool -printcert -jarfile "$AAB" 2>/dev/null | awk -F': ' '/SHA256:/ {print $2; exit}' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  if [[ -n "$CERT_SHA256" ]]; then
    echo "Release certificate SHA-256: $CERT_SHA256"
  fi
  if [[ -n "${EXPECTED_RELEASE_CERT_SHA256:-}" ]]; then
    EXPECTED_NORMALIZED="$(printf '%s' "$EXPECTED_RELEASE_CERT_SHA256" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    if [[ "$CERT_SHA256" != "$EXPECTED_NORMALIZED" ]]; then
      echo "Release certificate SHA-256 does not match EXPECTED_RELEASE_CERT_SHA256." >&2
      exit 1
    fi
    echo "Release certificate SHA-256 matches EXPECTED_RELEASE_CERT_SHA256."
  else
    echo "Set EXPECTED_RELEASE_CERT_SHA256 to gate the Play upload certificate fingerprint."
  fi
else
  echo "$SIGNATURE_OUTPUT" >&2
  echo "Release bundle signature: could not determine verification state." >&2
  exit 1
fi

echo "Android release verification completed."
