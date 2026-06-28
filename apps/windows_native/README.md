# Password Manager Windows Native

## 中文

该目录包含 Windows 原生重构目标。它与 `apps/flutter_app` 明确隔离，用于在不改动现有 Flutter Windows 实现和既有功能行为的前提下，逐步补齐 Windows 原生端能力。

### 范围

- 当前切片是 C++17 + Win32 的 Windows 原生起点。
- `src/win32_app.cpp` 提供最小 Win32 window skeleton，供后续接入真实 UI。
- `PasswordManagerWindows.vcxproj` 提供 Visual Studio / MSBuild 项目骨架。
- 可移植 core 复用 `apps/native_core` 的 C++17 + OpenSSL 路径，当前可在本机用 clang 构建和测试。
- 已实现可测试核心：PBKDF2-SHA256、AES-256-GCM encrypted vault envelope、TOTP、entry model、搜索/过滤、分类/标签集合、JSON snapshot 序列化/反序列化、encrypted vault 文件读写、version-vector merge。
- CLI 入口支持初始化、解锁状态检查、分类模板持久化、credential/server/service 条目新增、搜索列表、单条查看、软删除、TOTP 和 self-test，Windows/Linux 共用 `apps/native_core/src/vault_cli.cpp`。
- 当前尚未实现完整 Win32/WinUI 3/WPF 图形界面，也尚未实现 Windows Credential Manager / DPAPI 集成和真实 WebDAV/S3 网络同步。

### 目录说明

- `PasswordManagerWindows.vcxproj`: Visual Studio C++ Win32 app project skeleton，并引用共享 `vault_core` / `vault_cli` 源文件。
- `Makefile`: 非 Windows 环境下验证 portable core 的构建和测试入口。
- `src/win32_app.cpp`: 最小 Win32 window app。
- `src/main.cpp`: Windows native CLI entrypoint。
- `../native_core/src/vault_core.hpp`: 共享核心类型和 API。
- `../native_core/src/vault_core.cpp`: 共享 crypto、TOTP、entry、merge、分类模板和对象存储签名实现。
- `../native_core/src/vault_cli.cpp`: Windows/Linux 共享 terminal-native CLI。
- `../native_core/tests/vault_core_tests.cpp`: Windows/Linux 共用 C++ core tests。

### 环境要求

Windows 实机开发：

- Windows 10/11。
- Visual Studio 2022，安装 Desktop development with C++ workload。
- Windows 10/11 SDK。
- OpenSSL 3 for Windows，或后续替换为 CNG/BCrypt 原生实现。
- WiX Toolset 或 MSIX Packaging Tool，用于安装包。

当前本机验证：

- clang++。
- GNU Make。
- OpenSSL 3 headers/libs，默认路径 `/opt/homebrew/opt/openssl@3`。

### 开发

在当前非 Windows 环境验证 portable core：

```bash
make test
make
```

如果 OpenSSL 安装在非默认路径：

```bash
make OPENSSL_PREFIX=/path/to/openssl
```

在 Windows 上构建 Win32 skeleton：

```powershell
msbuild PasswordManagerWindows.vcxproj /p:Configuration=Release /p:Platform=x64
```

或在 Visual Studio 中打开 `PasswordManagerWindows.vcxproj` 后选择 `Release|x64` 构建。

### 本地功能验证

当前 portable core 验证：

1. 运行 `make test`。
2. 运行 self-test：

   ```bash
   ./build/password-manager-windows-core self-test
   ```

3. 生成 TOTP fixture：

   ```bash
   ./build/password-manager-windows-core totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 59
   ```

   期望输出 `287082`。

4. 初始化 encrypted vault 文件：

   ```bash
   ./build/password-manager-windows-core init "test-password"
   ```

5. 解锁并查看 vault 状态：

   ```bash
   ./build/password-manager-windows-core status "test-password"
   ```

6. 添加分类模板并确认能再次解锁读回：

   ```bash
   ./build/password-manager-windows-core add-category "test-password" Infra --shortcut server --field Owner
   ./build/password-manager-windows-core status "test-password"
   ```

7. 添加、搜索、查看和软删除条目。列表和查看默认隐藏 secret，只有显式传入 `--show-secret` 才显示：

   ```bash
   ./build/password-manager-windows-core add-entry "test-password" \
     --label "Prod Admin" \
     --type credential \
     --username admin@example.com \
     --secret super-secret \
     --category Infra \
     --tag prod \
     --field Owner=SRE
   ./build/password-manager-windows-core list "test-password" --query Owner:SRE
   ./build/password-manager-windows-core show-entry "test-password" "<entry-id>"
   ./build/password-manager-windows-core delete-entry "test-password" "<entry-id>"
   ```

8. 确认 `vault-windows-native.envelope` 包含 salt、iterations、verifier、nonce、ciphertext、mac，但不包含分类名、username 或 password 等 vault 明文。

Windows 实机验证还需要覆盖：

1. `.exe` 启动并显示原生窗口。
2. 初始化、解锁、锁定。
3. credential/server/service CRUD。
4. 搜索、分类和标签。
5. TOTP 解锁。
6. 导入导出、备份和恢复。
7. WebDAV/S3 真实服务同步。
8. 关闭进程和重启后的数据保留。
9. Windows 高 DPI、深色模式、键盘导航和屏幕阅读器基础可访问性。

### 发布构建

Visual Studio / MSBuild release build：

```powershell
msbuild PasswordManagerWindows.vcxproj /p:Configuration=Release /p:Platform=x64
```

发布前需要：

1. 设置应用名称、版本号、公司名、图标和 manifest。
2. 配置 Release 编译选项和运行库策略。
3. 接入 Windows 原生密钥保护：Credential Manager、DPAPI 或 CNG/BCrypt。
4. 生成 `.exe` 并进行代码签名：

   ```powershell
   signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a .\PasswordManagerWindows.exe
   ```

5. 在干净 Windows 10/11 VM 上安装/运行验证。

### Windows 分发 / 上架

可选分发渠道：

1. MSIX / Microsoft Store：
   - 创建 MSIX packaging project 或使用 MSIX Packaging Tool。
   - 配置 package identity、publisher、capabilities、icons、screenshot 和 privacy policy。
   - 在 Partner Center 创建 app submission。
   - 上传 signed MSIX / MSIXBundle。
   - 先走 private audience 或 package flight 验证，再提交正式审核。
2. MSI：
   - 使用 WiX Toolset 创建 installer。
   - 安装到 `Program Files`。
   - 添加 Start Menu shortcut、uninstall entry 和 upgrade code。
   - 对 MSI 和 EXE 进行代码签名。
3. Winget：
   - 发布 signed installer。
   - 准备 winget manifest。
   - 提交到 winget-pkgs 仓库。
4. 企业分发：
   - 使用 Intune、SCCM、MDM 或内部软件门户。
   - 记录签名证书、SHA256、SBOM、安装/卸载命令和升级策略。

Release notes 只能描述已经验证的能力；当前不能把完整 GUI、Windows Credential Manager 集成或真实远端同步写成已发布能力。

### 发布检查清单

- [x] Windows 原生目录在 `apps/windows_native` 下创建。
- [x] README 提供中文和英文版本。
- [x] README 说明开发、发布构建、Windows 分发/上架步骤。
- [x] Win32 app skeleton 和 Visual Studio `.vcxproj` 已添加。
- [x] Windows/Linux 原生端共用 `apps/native_core`，避免 core 双写偏差。
- [x] Portable core 使用 PBKDF2-SHA256 + AES-256-GCM。
- [x] C++ 测试覆盖加密 envelope、错误密码拒绝、snapshot 反序列化、encrypted vault 文件读回、TOTP、entry 过滤、集合重建和 version-vector merge。
- [x] portable smoke-test CLI 可在当前机器构建。
- [x] Windows/Linux 共用 terminal-native CLI，支持加密 vault 初始化、状态读取、分类模板持久化、条目新增/搜索/查看/软删除。
- [ ] 在 Windows 10/11 上用 Visual Studio/MSBuild 构建 `.exe`。
- [ ] 完整 Win32/WinUI 3/WPF UI 完成。
- [ ] 完整 CRUD、导入导出、备份恢复 GUI 完成。
- [ ] Windows Credential Manager / DPAPI / CNG 密钥保护完成。
- [ ] 真实 WebDAV/S3 远端同步完成。
- [ ] `.exe` 代码签名完成。
- [ ] MSIX/MSI/winget 至少一种安装包完成安装验证。
- [ ] Microsoft Store 或企业分发审核通过。

---

## English

This directory contains the native Windows rewrite target. It is intentionally separate from `apps/flutter_app` so the existing Flutter Windows implementation remains untouched while native Windows parity is built incrementally.

### Scope

- The current slice is a C++17 + Win32 native Windows starting point.
- `src/win32_app.cpp` provides a minimal Win32 window skeleton for future real UI work.
- `PasswordManagerWindows.vcxproj` provides a Visual Studio / MSBuild project scaffold.
- The portable core uses the shared `apps/native_core` C++17 + OpenSSL path and can currently be built and tested locally with clang.
- Testable core is implemented: PBKDF2-SHA256, AES-256-GCM encrypted vault envelope, TOTP, entry model, search/filtering, category/tag collection rebuilding, JSON snapshot serialization/deserialization, encrypted vault file read/write, and version-vector merge.
- The CLI supports initialization, unlock status checks, persisted category templates, credential/server/service entry add, search/list, single-entry view, soft delete, TOTP, and self-test through shared `apps/native_core/src/vault_cli.cpp`.
- Full Win32/WinUI 3/WPF GUI, Windows Credential Manager / DPAPI integration, and real WebDAV/S3 network sync are not implemented yet.

### Directory Layout

- `PasswordManagerWindows.vcxproj`: Visual Studio C++ Win32 app project skeleton with shared `vault_core` / `vault_cli` source references.
- `Makefile`: build and test entry point for the portable core outside Windows.
- `src/win32_app.cpp`: minimal Win32 window app.
- `src/main.cpp`: Windows native CLI entrypoint.
- `../native_core/src/vault_core.hpp`: shared core types and API.
- `../native_core/src/vault_core.cpp`: shared crypto, TOTP, entry, merge, category template, and object storage signing implementation.
- `../native_core/src/vault_cli.cpp`: shared Windows/Linux terminal-native CLI.
- `../native_core/tests/vault_core_tests.cpp`: shared Windows/Linux C++ core tests.

### Requirements

Windows device development:

- Windows 10/11.
- Visual Studio 2022 with the Desktop development with C++ workload.
- Windows 10/11 SDK.
- OpenSSL 3 for Windows, or later replacement with native CNG/BCrypt.
- WiX Toolset or MSIX Packaging Tool for installers.

Current local verification:

- clang++.
- GNU Make.
- OpenSSL 3 headers/libs, defaulting to `/opt/homebrew/opt/openssl@3`.

### Develop

Verify the portable core outside Windows:

```bash
make test
make
```

If OpenSSL is installed in a custom location:

```bash
make OPENSSL_PREFIX=/path/to/openssl
```

Build the Win32 skeleton on Windows:

```powershell
msbuild PasswordManagerWindows.vcxproj /p:Configuration=Release /p:Platform=x64
```

Or open `PasswordManagerWindows.vcxproj` in Visual Studio and build `Release|x64`.

### Local Feature Verification

Current portable core verification:

1. Run `make test`.
2. Run self-test:

   ```bash
   ./build/password-manager-windows-core self-test
   ```

3. Generate the TOTP fixture:

   ```bash
   ./build/password-manager-windows-core totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 59
   ```

   Expected output: `287082`.

4. Generate an encrypted envelope smoke-test file:

   ```bash
   ./build/password-manager-windows-core init "test-password"
   ```

5. Add, search, view, and soft-delete an entry. List and view output hide secrets unless `--show-secret` is passed:

   ```bash
   ./build/password-manager-windows-core add-entry "test-password" \
     --label "Prod Admin" \
     --type credential \
     --username admin@example.com \
     --secret super-secret \
     --category Infra \
     --tag prod \
     --field Owner=SRE
   ./build/password-manager-windows-core list "test-password" --query Owner:SRE
   ./build/password-manager-windows-core show-entry "test-password" "<entry-id>"
   ./build/password-manager-windows-core delete-entry "test-password" "<entry-id>"
   ```

6. Confirm `vault-windows-native.envelope` contains salt, iterations, verifier, nonce, ciphertext, and mac, but does not contain the sample entry plaintext username or password.

Windows device validation still needs:

1. `.exe` launches and shows a native window.
2. Setup, unlock, and lock.
3. Credential/server/service CRUD.
4. Search, categories, and tags.
5. TOTP unlock.
6. Import/export, backup, and restore.
7. Real WebDAV/S3 sync.
8. Data retention after process close and relaunch.
9. High DPI, dark mode, keyboard navigation, and baseline screen-reader accessibility.

### Release Build

Visual Studio / MSBuild release build:

```powershell
msbuild PasswordManagerWindows.vcxproj /p:Configuration=Release /p:Platform=x64
```

Before release:

1. Configure app name, version, company name, icon, and manifest.
2. Configure Release compiler options and runtime library strategy.
3. Add Windows-native key protection through Credential Manager, DPAPI, or CNG/BCrypt.
4. Generate `.exe` and code sign it:

   ```powershell
   signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a .\PasswordManagerWindows.exe
   ```

5. Install/run test on clean Windows 10/11 VMs.

### Windows Distribution / Submission

Available channels:

1. MSIX / Microsoft Store:
   - Create an MSIX packaging project or use MSIX Packaging Tool.
   - Configure package identity, publisher, capabilities, icons, screenshots, and privacy policy.
   - Create an app submission in Partner Center.
   - Upload signed MSIX / MSIXBundle.
   - Validate with private audience or package flight before submitting for public certification.
2. MSI:
   - Create an installer with WiX Toolset.
   - Install into `Program Files`.
   - Add Start Menu shortcut, uninstall entry, and upgrade code.
   - Code sign both MSI and EXE.
3. Winget:
   - Publish a signed installer.
   - Prepare a winget manifest.
   - Submit to the winget-pkgs repository.
4. Enterprise distribution:
   - Use Intune, SCCM, MDM, or an internal software portal.
   - Record signing certificate, SHA256, SBOM, install/uninstall commands, and upgrade policy.

Release notes must only describe verified capabilities. Do not list full GUI, Windows Credential Manager integration, or real remote sync as shipped yet.

### Release Checklist

- [x] Native Windows directory is created under `apps/windows_native`.
- [x] README provides Chinese and English versions.
- [x] README documents development, release build, Windows distribution/submission steps.
- [x] Win32 app skeleton and Visual Studio `.vcxproj` are added.
- [x] Portable core uses PBKDF2-SHA256 + AES-256-GCM.
- [x] C++ tests cover encrypted envelope, wrong-password rejection, TOTP, entry filtering, collection rebuilding, and version-vector merge.
- [x] Portable smoke-test CLI builds on the current machine.
- [x] Shared Windows/Linux terminal-native CLI supports encrypted vault initialization, status reads, category template persistence, and entry add/search/view/soft-delete.
- [ ] Build `.exe` on Windows 10/11 with Visual Studio/MSBuild.
- [ ] Full Win32/WinUI 3/WPF UI is complete.
- [ ] Full CRUD, import/export, and backup/restore GUI is complete.
- [ ] Windows Credential Manager / DPAPI / CNG key protection is complete.
- [ ] Real WebDAV/S3 remote sync is complete.
- [ ] `.exe` code signing is complete.
- [ ] At least one MSIX/MSI/winget installer is install-tested.
- [ ] Microsoft Store or enterprise distribution review is approved.
