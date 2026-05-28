#!/usr/bin/env bash
set -euo pipefail

if ! command -v dart >/dev/null 2>&1; then
  echo "Error: dart is not installed or not in PATH." >&2
  exit 127
fi

echo "==> Running package tests (Dart only)"
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

echo "All Dart package tests passed."
