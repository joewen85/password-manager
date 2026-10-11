#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Runs the locally verifiable Windows native release gate:
  - portable shared core release binary build
  - release binary self-test
  - assertion-enabled C++ core tests and shared CLI smoke coverage
  - Visual Studio / MSBuild project release contract verifier

This does not replace Windows-host MSBuild, code signing, or clean Windows VM
runtime dependency validation.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

command -v make >/dev/null 2>&1 || {
  echo "make is required to run the Windows native portable release gate." >&2
  exit 127
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to run the Windows release contract verifier." >&2
  exit 127
}

cd "$APP_ROOT"

echo "Running Windows native local release gate..."
make clean
make CXXFLAGS="-std=c++17 -Wall -Wextra -Wpedantic -O2 -DNDEBUG"
./build/password-manager-windows-core self-test
make clean
make test CXXFLAGS="-std=c++17 -Wall -Wextra -Wpedantic -O2"
python3 scripts/verify_release_contract.py

echo "Windows native local release gate completed."
