#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_NAME="${LINUX_PACKAGE_NAME:-password-manager-linux}"
PACKAGE_VERSION="${LINUX_PACKAGE_VERSION:-0.1.0}"
OUTPUT_DIR="${LINUX_PACKAGE_OUTPUT_DIR:-$APP_ROOT/dist}"
BINARY_PATH="${1:-$APP_ROOT/build/password-manager-linux}"
CONTROL_TEMPLATE="$APP_ROOT/packaging/deb/DEBIAN/control"
COPYRIGHT_TEMPLATE="$APP_ROOT/packaging/deb/copyright"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

ok() {
  printf '[OK] %s\n' "$1"
}

command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb is required to build a Debian package"
[[ -f "$BINARY_PATH" ]] || fail "Missing binary: $BINARY_PATH"
[[ -x "$BINARY_PATH" ]] || fail "Binary is not executable: $BINARY_PATH"
[[ -f "$CONTROL_TEMPLATE" ]] || fail "Missing Debian control template: $CONTROL_TEMPLATE"
[[ -f "$COPYRIGHT_TEMPLATE" ]] || fail "Missing copyright template: $COPYRIGHT_TEMPLATE"

ARCHITECTURE="${LINUX_PACKAGE_ARCHITECTURE:-$(dpkg --print-architecture)}"
PACKAGE_ROOT="$APP_ROOT/build/deb/${PACKAGE_NAME}_${PACKAGE_VERSION}_${ARCHITECTURE}"
DEBIAN_DIR="$PACKAGE_ROOT/DEBIAN"
INSTALL_BIN_DIR="$PACKAGE_ROOT/usr/bin"
DOC_DIR="$PACKAGE_ROOT/usr/share/doc/$PACKAGE_NAME"
PACKAGE_PATH="$OUTPUT_DIR/${PACKAGE_NAME}_${PACKAGE_VERSION}_${ARCHITECTURE}.deb"

case "$PACKAGE_NAME" in
  *[!a-z0-9+.-]*|'') fail "Invalid Debian package name: $PACKAGE_NAME" ;;
esac
case "$PACKAGE_VERSION" in
  *[!A-Za-z0-9.+:~_-]*|'') fail "Invalid Debian package version: $PACKAGE_VERSION" ;;
esac
case "$ARCHITECTURE" in
  *[!A-Za-z0-9-]*|'') fail "Invalid Debian package architecture: $ARCHITECTURE" ;;
esac

rm -rf "$PACKAGE_ROOT"
mkdir -p "$DEBIAN_DIR" "$INSTALL_BIN_DIR" "$DOC_DIR" "$OUTPUT_DIR"

install -m 0755 "$BINARY_PATH" "$INSTALL_BIN_DIR/password-manager-linux"
install -m 0644 "$COPYRIGHT_TEMPLATE" "$DOC_DIR/copyright"

INSTALLED_SIZE="$(du -sk "$PACKAGE_ROOT/usr" | awk '{ print $1 }')"
sed \
  -e "s/@PACKAGE_NAME@/$PACKAGE_NAME/g" \
  -e "s/@VERSION@/$PACKAGE_VERSION/g" \
  -e "s/@ARCHITECTURE@/$ARCHITECTURE/g" \
  -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/g" \
  "$CONTROL_TEMPLATE" >"$DEBIAN_DIR/control"
chmod 0644 "$DEBIAN_DIR/control"

dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$PACKAGE_PATH"

ok "Built Debian package: $PACKAGE_PATH"
dpkg-deb --info "$PACKAGE_PATH"
