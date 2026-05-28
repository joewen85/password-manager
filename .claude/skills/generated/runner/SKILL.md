---
name: runner
description: "Skill for the Runner area of password-manager. 8 symbols across 6 files."
---

# Runner

8 symbols | 6 files | Cohesion: 100%

## When to Use

- Working with code in `apps/`
- Understanding how GetCommandLineArguments, Utf8FromUtf16, my_application_new work
- Modifying runner-related functionality

## Key Files

| File | Symbols |
|------|---------|
| `apps/flutter_app/windows/runner/win32_window.cpp` | WindowClassRegistrar, GetInstance |
| `apps/flutter_app/windows/runner/utils.cpp` | GetCommandLineArguments, Utf8FromUtf16 |
| `apps/flutter_app/windows/runner/win32_window.h` | Win32Window |
| `apps/flutter_app/windows/runner/flutter_window.h` | FlutterWindow |
| `apps/flutter_app/linux/runner/my_application.h` | my_application_new |
| `apps/flutter_app/linux/runner/main.cc` | main |

## Entry Points

Start here when exploring this area:

- **`GetCommandLineArguments`** (Function) — `apps/flutter_app/windows/runner/utils.cpp:23`
- **`Utf8FromUtf16`** (Function) — `apps/flutter_app/windows/runner/utils.cpp:43`
- **`my_application_new`** (Function) — `apps/flutter_app/linux/runner/my_application.h:18`
- **`main`** (Function) — `apps/flutter_app/linux/runner/main.cc:2`
- **`Win32Window`** (Class) — `apps/flutter_app/windows/runner/win32_window.h:12`

## Key Symbols

| Symbol | Type | File | Line |
|--------|------|------|------|
| `Win32Window` | Class | `apps/flutter_app/windows/runner/win32_window.h` | 12 |
| `FlutterWindow` | Class | `apps/flutter_app/windows/runner/flutter_window.h` | 11 |
| `WindowClassRegistrar` | Class | `apps/flutter_app/windows/runner/win32_window.cpp` | 58 |
| `GetCommandLineArguments` | Function | `apps/flutter_app/windows/runner/utils.cpp` | 23 |
| `Utf8FromUtf16` | Function | `apps/flutter_app/windows/runner/utils.cpp` | 43 |
| `my_application_new` | Function | `apps/flutter_app/linux/runner/my_application.h` | 18 |
| `main` | Function | `apps/flutter_app/linux/runner/main.cc` | 2 |
| `GetInstance` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 63 |

## How to Explore

1. `gitnexus_context({name: "GetCommandLineArguments"})` — see callers and callees
2. `gitnexus_query({query: "runner"})` — find related execution flows
3. Read key files listed above for implementation details
