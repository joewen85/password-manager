#!/usr/bin/env bash
set -euo pipefail

if ! command -v dart >/dev/null 2>&1; then
  echo "Error: dart is not installed or not in PATH." >&2
  exit 127
fi

echo "==> Running package tests"
(
  cd packages/crypto
  dart test
)
(
  cd packages/auth
  dart test
)
(
  cd packages/core
  dart test
)
(
  cd packages/storage
  dart test
)

echo "==> Running static analysis for interface-only packages"
(
  cd packages/sync
  dart analyze --fatal-infos
)
(
  cd packages/backup
  dart analyze --fatal-infos
)

echo "All shared Dart package checks passed."
