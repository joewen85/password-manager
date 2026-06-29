#!/usr/bin/env bash
set -euo pipefail

DEB_PATH="${1:-}"
PACKAGE_NAME="${LINUX_PACKAGE_NAME:-password-manager-linux}"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

ok() {
  printf '[OK] %s\n' "$1"
}

[[ -n "$DEB_PATH" ]] || fail "Usage: $(basename "$0") <path-to-deb>"
[[ -f "$DEB_PATH" ]] || fail "Debian package does not exist: $DEB_PATH"
command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb is required"
command -v dpkg >/dev/null 2>&1 || fail "dpkg is required"

dpkg-deb --info "$DEB_PATH"
dpkg-deb --contents "$DEB_PATH" | tee /tmp/password-manager-linux.deb.contents
grep -q "./usr/bin/password-manager-linux" /tmp/password-manager-linux.deb.contents
grep -q "./usr/share/doc/$PACKAGE_NAME/copyright" /tmp/password-manager-linux.deb.contents
ok "Debian package contains binary and copyright metadata"

if command -v apt-get >/dev/null 2>&1; then
  apt-get install -y "$DEB_PATH"
else
  [[ "$(id -u)" == "0" ]] || fail "Root privileges are required for dpkg -i"
  dpkg -i "$DEB_PATH"
fi

command -v password-manager-linux >/tmp/password-manager-linux.which
grep -q "/usr/bin/password-manager-linux" /tmp/password-manager-linux.which
dpkg -s "$PACKAGE_NAME" | tee /tmp/password-manager-linux.dpkg-status
grep -q "Status: install ok installed" /tmp/password-manager-linux.dpkg-status
dpkg -L "$PACKAGE_NAME" | tee /tmp/password-manager-linux.dpkg-files
grep -q "/usr/bin/password-manager-linux" /tmp/password-manager-linux.dpkg-files

file /usr/bin/password-manager-linux | tee /tmp/password-manager-linux.installed.file
grep -Eq "ELF .* executable|ELF .* pie executable" /tmp/password-manager-linux.installed.file
ldd /usr/bin/password-manager-linux | tee /tmp/password-manager-linux.installed.ldd
grep -q "libcrypto" /tmp/password-manager-linux.installed.ldd
grep -q "libcurl" /tmp/password-manager-linux.installed.ldd

password-manager-linux self-test
ok "Installed Debian package runs self-test from /usr/bin"

if command -v apt-get >/dev/null 2>&1; then
  apt-get purge -y "$PACKAGE_NAME"
else
  dpkg -r "$PACKAGE_NAME"
fi
hash -r 2>/dev/null || true
if [[ -e /usr/bin/password-manager-linux ]] || command -v password-manager-linux >/dev/null 2>&1; then
  fail "password-manager-linux command still exists after package removal"
fi
ok "Debian package uninstall removes the CLI command"
