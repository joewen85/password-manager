$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Error "$name is not installed or not in PATH."
    exit 127
  }
}

Require-Command dart

Write-Host "==> Running package tests (Dart only)"
Push-Location packages/crypto
  dart test
Pop-Location

Push-Location packages/auth
  dart test
Pop-Location

Push-Location packages/core
  dart test
Pop-Location

Push-Location packages/storage
  dart test
Pop-Location

Write-Host "==> Running static analysis for interface-only packages"
Push-Location packages/sync
  dart analyze --fatal-infos
Pop-Location

Push-Location packages/backup
  dart analyze --fatal-infos
Pop-Location

Write-Host "All shared Dart package checks passed."
