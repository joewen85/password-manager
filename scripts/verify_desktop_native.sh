#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_LINUX_DOCKER=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--linux-docker]

Runs the Windows/Linux native verification gates that are available on the
current host. This covers the shared C++ core, shared CLI smoke tests, Windows
release contract checks, and Linux host binary dependency inspection.

Options:
  --linux-docker  Also run the Linux Docker release gate for real Linux
                  userspace and .deb install/uninstall validation.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-docker)
      RUN_LINUX_DOCKER=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

echo "==> Windows native release gate"
"$ROOT_DIR/apps/windows_native/scripts/verify_release.sh"

echo "==> Linux native release gate"
if [[ "$RUN_LINUX_DOCKER" == "true" ]]; then
  "$ROOT_DIR/apps/linux_native/scripts/verify_release.sh" --docker
else
  "$ROOT_DIR/apps/linux_native/scripts/verify_release.sh"
fi

echo "Windows/Linux native verification completed."
