#!/usr/bin/env bash
set -euo pipefail

if ! command -v dart >/dev/null 2>&1; then
  echo "Error: dart is not installed or not in PATH." >&2
  exit 127
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Error: flutter is not installed or not in PATH." >&2
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

echo "==> Running app widget tests"
(
  cd apps/flutter_app
  flutter test
)

echo "All tests passed."
