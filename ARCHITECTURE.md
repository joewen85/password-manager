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

## Vault Data Contract
- Vault state is stored as encrypted JSON snapshots; there is no database schema or database migration in the current architecture.
- Category-template fields may declare `valueType=entryReference` and a `targetCategory`. The matching entry custom field stores the target entry's stable opaque ID and the defining `templateFieldId`.
- Tags remain a separate loose taxonomy for grouping, search, and filtering; they are never interpreted as entry references.
- Missing additive properties decode to legacy text-field defaults, while unknown non-empty field types and non-UUID IDs are preserved losslessly.
- Scoped item/category exports carry the source category template but never expand referenced entries implicitly. See `docs/FIELD_REFERENCE_CONTRACT.md` for the complete compatibility, lifecycle, import/export, and rollout contract.

## Extensibility
All module interfaces are designed to allow new providers (e.g., S3, WebDAV, NAS SMB) without changing core logic.

## Native App Strategy
Native apps should keep platform concerns separate from shared vault behavior:
- Reuse the vault data contract, sync payload format, AES-GCM payload format, PBKDF2 parameters, and TOTP verification rules.
- Implement platform UI, secure storage, file access, and network adapters natively.
- Keep native app state thin; credential encryption, vault merge semantics, import/export validation, and sync conflict rules should stay testable outside the UI runtime.
- Swift, Kotlin, HarmonyOS, and desktop native ports should keep compatibility tests against `packages/crypto`, `packages/auth`, and representative vault payload fixtures.
- All maintained clients must complete lossless reference-field read/write support before any client exposes reference editing, because the current sync envelope has no peer-capability negotiation.
