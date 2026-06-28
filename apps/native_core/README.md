# Password Manager Native Core

Shared C++17 core used by the native Windows and Linux clients.

This module keeps platform-neutral vault behavior in one place so Windows and
Linux do not drift while native client parity is built. Platform projects should
link these sources instead of copying them into each app directory.

## Contents

- `src/vault_core.hpp`: shared native types and API.
- `src/vault_core.cpp`: crypto, TOTP, search, taxonomy templates, merge, and
  object storage request signing helpers.
- `tests/vault_core_tests.cpp`: shared regression tests run by both
  `apps/windows_native` and `apps/linux_native`.

## Verify

Run the platform Makefile tests:

```bash
cd ../windows_native && make test
cd ../linux_native && make test
```
