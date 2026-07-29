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
- Category create/delete/recreate state is preserved through additive
  `categoryStates` version vectors and remove-wins tombstones. The sync merge
  also clears stale category references from active entries; see
  `../../docs/CATEGORY_SYNC_CONTRACT.md`.
- The entry-reference data contract is preserved in shared snapshot and sync
  serialization. The shared core also resolves opaque target IDs into
  `empty`, `resolved`, `missing`, `deleted`, or category-mismatch states while
  exposing only the target ID, label, and category to trusted domain callers. Its domain helper propagates
  matching category-renamed target configuration, while category deletion and
  target delete/restore/move scenarios retain stored reference values. Search
  projects only resolved target labels/categories and suppresses stored IDs,
  target secrets, unknown field values, and orphaned binding values. `show-entry`
  keeps known text and ad-hoc text values, renders reference values as `empty`,
  `resolved: <label> - <category>`, `missing`, `deleted`, or `categoryMismatch`,
  and blanks unknown/orphan values. This remains true with `--show-secret`, which
  only controls the selected entry's own secret. A pure import helper remaps
  references through a complete copy ID map, and conflict-copy tests verify
  reference values plus template field IDs. Reference editing and a scoped-copy
  CLI flow remain outside this slice; see `../../docs/FIELD_REFERENCE_CONTRACT.md`.

`export-snapshot` is a lossless plaintext data export, not a display projection.
It intentionally retains stored reference IDs and unknown/orphan values so a
later import can restore them. Treat the export as sensitive vault data and do
not print or log it.

## Verify

Run the platform Makefile tests:

```bash
cd ../windows_native && make test
cd ../linux_native && make test
```

Run the Windows/Linux native release gates from the repository root:

```bash
./scripts/verify_desktop_native.sh
```

Add `--linux-docker` to include the Linux Docker userspace and `.deb`
install/uninstall gate.

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
