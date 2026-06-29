$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Error "$name is not installed or not in PATH."
    exit 127
  }
}

Require-Command dart

Write-Host "==> Running package tests"
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

Write-Host "All tests passed."
