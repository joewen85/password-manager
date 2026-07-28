#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DOCKER=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--docker]

Runs the locally verifiable Linux native release gate:
  - shared core release binary build
  - release binary self-test
  - assertion-enabled C++ core tests and shared CLI smoke coverage
  - binary dependency inspection for the current host

Options:
  --docker  Also run scripts/verify_release_docker.sh for a real Linux
            userspace build, ELF/dependency checks, and .deb install test.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker)
      RUN_DOCKER=true
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

command -v make >/dev/null 2>&1 || {
  echo "make is required to run the Linux native release gate." >&2
  exit 127
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to run the CLI field-reference contract checks." >&2
  exit 127
}

cd "$APP_ROOT"

echo "Running Linux native local release gate..."
make clean
make CXXFLAGS="-std=c++17 -Wall -Wextra -Wpedantic -O2 -DNDEBUG"
./build/password-manager-linux self-test

file build/password-manager-linux | tee /tmp/password-manager-linux.local.file
case "$(uname -s)" in
  Linux)
    grep -Eq "ELF .* executable|ELF .* pie executable" /tmp/password-manager-linux.local.file
    ldd build/password-manager-linux | tee /tmp/password-manager-linux.local.ldd
    grep -q "libcrypto" /tmp/password-manager-linux.local.ldd
    grep -q "libcurl" /tmp/password-manager-linux.local.ldd
    ;;
  Darwin)
    grep -q "Mach-O" /tmp/password-manager-linux.local.file
    otool -L build/password-manager-linux | tee /tmp/password-manager-linux.local.otool
    grep -q "libcrypto" /tmp/password-manager-linux.local.otool
    grep -q "libcurl" /tmp/password-manager-linux.local.otool
    ;;
  *)
    echo "[WARN] Skipping host binary dependency inspection for $(uname -s)." >&2
    ;;
esac

make clean
make test CXXFLAGS="-std=c++17 -Wall -Wextra -Wpedantic -O2"

if [[ "$RUN_DOCKER" == "true" ]]; then
  scripts/verify_release_docker.sh
fi

echo "Linux native local release gate completed."
