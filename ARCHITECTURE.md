# Architecture

## Overview
The project is structured as native platform apps plus modular shared packages. Sensitive data is encrypted end-to-end using AES-256 (GCM), and persisted as encrypted blobs. Sync providers and backup engines are pluggable.

## Modules
- **Native Apps** (`apps/*_native`, `apps/harmony_app`)
  - Platform-specific UI and platform integration layers.
- **Native Core** (`apps/native_core`)
  - Shared C++17 core used by the native Windows and Linux clients.
- **Crypto Module** (`packages/crypto`)
  - AES-256-GCM encryption/decryption
  - Key derivation (PBKDF2/Argon2 planned)
- **Storage Module** (`packages/storage`)
  - Local encrypted store (file based)
  - Interfaces for alternative stores
- **Sync Module** (`packages/sync`)
  - Provider interface for cloud/NAS sync
  - Conflict resolution strategy (planned)
- **Auth Module** (`packages/auth`)
  - TOTP 2FA generation and verification
- **Backup Module** (`packages/backup`)
  - Scheduled encrypted backups
  - Rotation & retention policy (planned)
- **Core** (`packages/core`)
  - Domain entities, repositories, and orchestration

## Data Flow
1. User inputs data in UI
2. Core validates and sends to Crypto for encryption
3. Storage persists encrypted payload
4. Sync provider (if enabled) uploads encrypted payload
5. Backup service schedules periodic snapshots

## Extensibility
All module interfaces are designed to allow new providers (e.g., S3, WebDAV, NAS SMB) without changing core logic.

## Native App Strategy
Native apps should keep platform concerns separate from shared vault behavior:
- Reuse the vault data contract, sync payload format, AES-GCM payload format, PBKDF2 parameters, and TOTP verification rules.
- Implement platform UI, secure storage, file access, and network adapters natively.
- Keep native app state thin; credential encryption, vault merge semantics, import/export validation, and sync conflict rules should stay testable outside the UI runtime.
- Swift, Kotlin, HarmonyOS, and desktop native ports should keep compatibility tests against `packages/crypto`, `packages/auth`, and representative vault payload fixtures.
