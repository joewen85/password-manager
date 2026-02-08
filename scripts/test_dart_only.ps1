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

Push-Location packages/core
  dart test
Pop-Location

Push-Location packages/storage
  dart test
Pop-Location

Write-Host "All Dart package tests passed."
