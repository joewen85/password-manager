# Password Manager Native Core

Shared C++17 core used by the native Windows and Linux clients.

This module keeps platform-neutral vault behavior in one place so Windows and
Linux do not drift while native client parity is built. Platform projects should
link these sources instead of copying them into each app directory.

## Contents

- `src/vault_core.hpp`: shared native types and API.
- `src/vault_core.cpp`: crypto, TOTP, search, taxonomy templates, merge, and
  object storage request signing helpers.
- `src/vault_cli.cpp`: shared CLI flows, including encrypted vault CRUD,
  password-stdin unlock, TOTP-protected vault enforcement,
  backup/export/import, and libcurl-backed remote object sync.
- `tests/vault_core_tests.cpp`: shared regression tests run by both
  `apps/windows_native` and `apps/linux_native`.

## Verify

Run the platform Makefile tests:

```bash
cd ../windows_native && make test
cd ../linux_native && make test
```

The CLI sync command supports WebDAV, S3-compatible presigned URLs, Tencent COS,
and Aliyun OSS object transport. Tencent COS and Aliyun OSS require access key,
secret key, and bucket values at runtime; sync state stores remote fingerprints
and local dirty flags only, not provider secrets.

For production use, prefer `--password-stdin` so the master password does not
appear in the process argv list or shell history:

```bash
printf '%s\n' "$PM_PASSWORD" | ./build/password-manager-linux status --password-stdin
```

Vaults with `security.requireTotp=true` also require `--totp-code <code>` or
`--totp-stdin` on every command that unlocks the encrypted vault. The legacy
positional password form remains available for backward compatibility and
existing smoke automation.

For sync secrets, prefer the stdin forms: `--remote-password-stdin` for WebDAV,
`--sk-stdin` / `--secret-key-stdin` for object-storage secret keys, and
`--download-url-stdin` / `--upload-url-stdin` for presigned URLs.
