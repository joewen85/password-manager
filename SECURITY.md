# Security Practices

## Encryption
- All sensitive fields are encrypted using AES‑256‑GCM.
- Encryption keys are derived from a master password (KDF configurable).
- Nonces are unique per encryption operation.

## Authentication
- TOTP‑based 2FA supported (RFC 6238 compliant).
- Master password is never stored; only salted KDF metadata.

## Storage & Sync
- Local data is stored only as encrypted blobs.
- Sync providers only ever see encrypted payloads.
- Backups are encrypted and integrity‑checked.

## Threat Mitigations
- Memory zeroization where applicable (planned)
- Tamper‑evident metadata (planned)
- Rate limiting on unlock attempts (planned)

## Auditing
- Prefer open‑source libraries with active maintenance.
- Security reviews required for crypto changes.
