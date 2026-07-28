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
- Entry-reference definitions and values remain inside the existing encrypted vault snapshot and require no new platform permission or network endpoint.
- Scoped item/category export does not automatically include a referenced entry. A reference must never expose or cause search/log indexing of the target entry's password, token, secret, or other sensitive fields.
- Reference fields can only be enabled for editing after every synchronized maintained client supports lossless preservation of the additive contract fields.

## Threat Mitigations
- Memory zeroization where applicable (planned)
- Tamper‑evident metadata (planned)
- Rate limiting on unlock attempts (planned)

## Auditing
- Prefer open‑source libraries with active maintenance.
- Security reviews required for crypto changes.
