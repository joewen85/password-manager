#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
IMAGE="${LINUX_RELEASE_DOCKER_IMAGE:-ubuntu:24.04}"
CONTAINER_CXX="${LINUX_RELEASE_CXX:-g++}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Builds and tests the Linux native CLI inside a real Linux distribution
container. On apt-based images, it also builds, installs, runs, and uninstalls
the CLI Debian package. Override with:

  LINUX_RELEASE_DOCKER_IMAGE=ubuntu:24.04 $(basename "$0")
  LINUX_RELEASE_CXX=g++ $(basename "$0")
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

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to run the Linux release verifier." >&2
  exit 1
fi

echo "Running Linux release verification in Docker image: $IMAGE"
docker run --rm \
  -e CONTAINER_CXX="$CONTAINER_CXX" \
  -v "$REPO_ROOT/apps/linux_native:/src/linux_native:ro" \
  -v "$REPO_ROOT/apps/native_core:/src/native_core:ro" \
  "$IMAGE" \
  bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        dpkg-dev \
        file \
        libcurl4-openssl-dev \
        libssl-dev \
        make \
        python3
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y \
        file \
        gcc-c++ \
        libcurl-devel \
        make \
        openssl-devel \
        python3
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache \
        build-base \
        curl-dev \
        file \
        make \
        openssl-dev \
        python3
    else
      echo "Unsupported Linux image: no apt-get, dnf, or apk package manager found." >&2
      exit 1
    fi

    mkdir -p /work/apps
    cp -a /src/linux_native /work/apps/linux_native
    cp -a /src/native_core /work/apps/native_core

    cd /work/apps/linux_native
    make clean
    make \
      CXX="$CONTAINER_CXX" \
      OPENSSL_PREFIX=/usr \
      CXXFLAGS="-std=c++17 -Wall -Wextra -Wpedantic -O2 -DNDEBUG"
    make test \
      CXX="$CONTAINER_CXX" \
      OPENSSL_PREFIX=/usr \
      CXXFLAGS="-std=c++17 -Wall -Wextra -Wpedantic -O2 -DNDEBUG"

    file build/password-manager-linux | tee /tmp/password-manager-linux.file
    grep -Eq "ELF .* executable|ELF .* pie executable" /tmp/password-manager-linux.file

    ldd build/password-manager-linux | tee /tmp/password-manager-linux.ldd
    grep -q "libcrypto" /tmp/password-manager-linux.ldd
    grep -q "libcurl" /tmp/password-manager-linux.ldd

    ./build/password-manager-linux self-test

    if command -v apt-get >/dev/null 2>&1; then
      make package-deb \
        CXX="$CONTAINER_CXX" \
        OPENSSL_PREFIX=/usr \
        CXXFLAGS="-std=c++17 -Wall -Wextra -Wpedantic -O2 -DNDEBUG"
      deb_path="$(find dist -maxdepth 1 -name "password-manager-linux_*.deb" -print -quit)"
      test -n "$deb_path"
      bash scripts/verify_install_deb.sh "$PWD/$deb_path"
    else
      echo "[WARN] Skipping Debian package install check on non-apt image."
    fi
  '

echo "Linux release verification completed."
