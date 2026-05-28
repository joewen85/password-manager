# Security Practices

## Encryption
- All sensitive fields are encrypted using AES‑256‑GCM.
- New encryption keys are derived from a master password with PBKDF2-HMAC-SHA256 at 600,000 iterations and 16-byte random salts.
- Existing vault records keep their stored KDF iteration count for backward-compatible unlocks and migration.
- Nonces are unique per encryption operation.

## Authentication
- TOTP‑based 2FA supported (RFC 6238 compliant).
- TOTP verification accepts the current time step plus one adjacent time step on either side, and compares candidate codes without early exit.
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
