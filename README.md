# Password Manager (Cross‑Platform)

A cross‑platform password manager that stores usernames, passwords, tokens, app IDs, access tokens, and secret keys. The goal is a secure, modern, and extensible system that runs on Windows, macOS, Linux, iOS, and Android.

## Goals
- AES‑256 encryption for all sensitive data
- Auto‑sync across devices (cloud/NAS support)
- 2FA (TOTP) for account access
- Encrypted backups
- Open‑source tech stack, maintainable architecture

## Structure
- `apps/flutter_app`: Cross‑platform UI (Flutter)
- `packages/crypto`: AES‑256 encryption service
- `packages/storage`: Encrypted local storage
- `packages/sync`: Cloud/NAS sync interfaces
- `packages/auth`: 2FA (TOTP) service
- `packages/backup`: Encrypted backup service
- `packages/core`: Domain models and orchestrator

## Getting Started (planned)
- Install Flutter SDK
- `cd apps/flutter_app`
- `flutter pub get`
- `flutter run`

## Security
See `SECURITY.md` for security design and practices.
