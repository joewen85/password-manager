---
name: runner
description: "Skill for the Runner area of password-manager. 20 symbols across 7 files."
---

# Runner

20 symbols | 7 files | Cohesion: 100%

## When to Use

- Working with code in `apps/`
- Understanding how window, CreateAndAttachConsole, GetCommandLineArguments work
- Modifying runner-related functionality

## Key Files

| File | Symbols |
|------|---------|
| `apps/flutter_app/windows/runner/win32_window.cpp` | Scale, WindowClassRegistrar, GetInstance, ~Win32Window, Create (+7) |
| `apps/flutter_app/windows/runner/utils.h` | CreateAndAttachConsole, GetCommandLineArguments |
| `apps/flutter_app/windows/runner/utils.cpp` | GetCommandLineArguments, Utf8FromUtf16 |
| `apps/flutter_app/windows/runner/flutter_window.cpp` | OnCreate |
| `apps/flutter_app/windows/runner/main.cpp` | window |
| `apps/flutter_app/linux/runner/main.cc` | main |
| `apps/flutter_app/linux/runner/my_application.h` | my_application_new |

## Entry Points

Start here when exploring this area:

- **`window`** (Function) — `apps/flutter_app/windows/runner/main.cpp:26`
- **`CreateAndAttachConsole`** (Function) — `apps/flutter_app/windows/runner/utils.h:8`
- **`GetCommandLineArguments`** (Function) — `apps/flutter_app/windows/runner/utils.h:16`
- **`main`** (Function) — `apps/flutter_app/linux/runner/main.cc:2`
- **`my_application_new`** (Function) — `apps/flutter_app/linux/runner/my_application.h:18`

## Key Symbols

| Symbol | Type | File | Line |
|--------|------|------|------|
| `WindowClassRegistrar` | Class | `apps/flutter_app/windows/runner/win32_window.cpp` | 58 |
| `window` | Function | `apps/flutter_app/windows/runner/main.cpp` | 26 |
| `CreateAndAttachConsole` | Function | `apps/flutter_app/windows/runner/utils.h` | 8 |
| `GetCommandLineArguments` | Function | `apps/flutter_app/windows/runner/utils.h` | 16 |
| `main` | Function | `apps/flutter_app/linux/runner/main.cc` | 2 |
| `my_application_new` | Function | `apps/flutter_app/linux/runner/my_application.h` | 18 |
| `GetCommandLineArguments` | Function | `apps/flutter_app/windows/runner/utils.cpp` | 23 |
| `Utf8FromUtf16` | Function | `apps/flutter_app/windows/runner/utils.cpp` | 43 |
| `OnCreate` | Method | `apps/flutter_app/windows/runner/flutter_window.cpp` | 11 |
| `~Win32Window` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 117 |
| `Create` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 122 |
| `MessageHandler` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 175 |
| `Destroy` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 223 |
| `SetChildContent` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 240 |
| `GetClientArea` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 251 |
| `OnCreate` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 265 |
| `OnDestroy` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 270 |
| `UpdateTheme` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 274 |
| `Scale` | Function | `apps/flutter_app/windows/runner/win32_window.cpp` | 35 |
| `GetInstance` | Method | `apps/flutter_app/windows/runner/win32_window.cpp` | 63 |

## Execution Flows

| Flow | Type | Steps |
|------|------|-------|
| `Create → WindowClassRegistrar` | intra_community | 4 |

## How to Explore

1. `context({name: "window"})` — see callers and callees
2. `query({query: "runner"})` — find related execution flows
3. Read key files listed above for implementation details
