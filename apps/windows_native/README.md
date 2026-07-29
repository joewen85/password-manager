# Password Manager Windows Native

## 中文

该目录包含 Windows 原生应用，用于逐步补齐 Windows 端原生能力。

### 范围

- 当前切片是 C++17 + Win32 的 Windows 原生起点。
- `src/win32_app.cpp` 提供最小 Win32 window skeleton，供后续接入真实 UI。
- `PasswordManagerWindows.vcxproj` 提供 Visual Studio / MSBuild 项目骨架，并声明 vcpkg manifest、Release 运行库/安全选项和 OpenSSL/libcurl 链接合同。
- 可移植 core 复用 `apps/native_core` 的 C++17 + OpenSSL 路径，当前可在本机用 clang 构建和测试。
- 已实现可测试核心：PBKDF2-SHA256、AES-256-GCM encrypted vault envelope、TOTP、entry model、搜索/过滤、分类/标签集合、JSON snapshot 序列化/反序列化、encrypted vault 文件读写、version-vector merge。
- CLI 入口支持初始化、`--password-stdin` 主密码输入、TOTP vault 解锁强制校验、解锁状态检查、分类模板持久化、credential/server/service 条目新增、搜索列表、单条查看、软删除、本地 encrypted envelope 备份/恢复、明文 snapshot 导出/导入、TOTP、WebDAV / S3 presigned URL / 腾讯云 COS / 阿里云 OSS 远端对象同步和 self-test，Windows/Linux 共用 `apps/native_core/src/vault_cli.cpp`。
- 共享 C++ core 已无损保留字段关联契约，并提供五态解析、生命周期传播、安全搜索投影、纯 copy-import ID 重映射 helper 和同步冲突保真测试。CLI 搜索只使用成功解析目标的名称/分类，不索引原始引用 ID、目标秘密、未知字段值或孤儿绑定值；`show-entry` 将引用安全展示为 `empty`、`resolved: <名称> - <分类>`、`missing`、`deleted` 或 `categoryMismatch`，即使传入 `--show-secret` 也不会泄露上述原值或目标秘密。`export-snapshot` 是用于无损往返的敏感明文数据边界，会保留原始引用 ID 和未知/孤儿值。标签职责不变，CLI 暂不提供关联编辑或 scoped-copy 导入流程，格式与上线顺序见 `../../docs/FIELD_REFERENCE_CONTRACT.md`。
- P7 已让共享 core 在快照和同步 JSON 中无损保留新的 `fieldReference` 与不透明 `targetFieldId`；旧数据缺失该属性时默认空字符串，未知字段类型也不会丢失它。本阶段不在 Windows CLI 中解析或展示字段级关系，相关领域行为由后续 P8 统一接入。
- 当前尚未实现完整 Win32/WinUI 3/WPF 图形界面，也尚未实现 Windows Credential Manager / DPAPI 集成、GUI 同步入口、Windows 实机 MSBuild 构建验证和干净 Windows VM 运行时依赖验证。

### 目录说明

- `PasswordManagerWindows.vcxproj`: Visual Studio C++ Win32 app project skeleton，并引用共享 `vault_core` / `vault_cli` 源文件。
- `vcpkg.json`: Visual Studio / MSBuild release 依赖 manifest，声明 OpenSSL 和 libcurl。
- `scripts/verify_release_contract.py`: 本机可运行的 Windows release contract verifier，解析 `.vcxproj` / `vcpkg.json` / README。
- `Makefile`: 非 Windows 环境下验证 portable core 的构建和测试入口。
- `src/win32_app.cpp`: 最小 Win32 window app。
- `src/main.cpp`: Windows native CLI entrypoint。
- `../native_core/src/vault_core.hpp`: 共享核心类型和 API。
- `../native_core/src/vault_core.cpp`: 共享 crypto、TOTP、entry、merge、分类模板和对象存储签名实现。
- `../native_core/src/vault_cli.cpp`: Windows/Linux 共享 terminal-native CLI。
- `../native_core/tests/vault_core_tests.cpp`: Windows/Linux 共用 C++ core tests。
- `../native_core/tests/vault_cli_smoke.sh`: 使用当前平台 CLI 产物验证字段关联五态安全展示、搜索抑制和 `export-snapshot` 无损保真。

### 环境要求

Windows 实机开发：

- Windows 10/11。
- Visual Studio 2022，安装 Desktop development with C++ workload。
- Windows 10/11 SDK。
- vcpkg 已接入 Visual Studio / MSBuild integration，工程通过 `VcpkgEnableManifest` 和 `x64-windows` triplet 恢复 OpenSSL 3 与 libcurl。
- WiX Toolset 或 MSIX Packaging Tool，用于安装包。

当前本机验证：

- clang++。
- GNU Make。
- OpenSSL 3 headers/libs，默认路径 `/opt/homebrew/opt/openssl@3`。
- libcurl headers/libs，可通过 `curl-config` 被 Makefile 自动发现。
- Python 3，用于运行 Windows release contract verifier。

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

在当前机器验证 Visual Studio / MSBuild release contract，不会冒充 Windows `.exe` 已构建：

```bash
python3 scripts/verify_release_contract.py
```

运行本机可验证的 Windows native release gate：

```bash
./scripts/verify_release.sh
```

该脚本会先构建 portable shared core release binary 并执行 CLI `self-test`，再执行启用 `assert` 的 C++ core tests、共享 CLI smoke（包括字段关联五态安全展示/搜索与无损导出合同）和 Visual Studio / MSBuild release contract verifier；它不替代 Windows 实机 MSBuild、签名或干净 VM 安装验证。

### 本地功能验证

当前 portable core 验证：

1. 运行 `make test`。
2. 运行 self-test：

   ```bash
   ./build/password-manager-windows-core self-test
   ```

   生产或多人机器上建议用 stdin 传入主密码，避免主密码进入进程 argv 或 shell history：

   ```bash
   printf '%s\n' "$PM_PASSWORD" | ./build/password-manager-windows-core status --password-stdin
   ```

   如果 vault 启用了 TOTP，所有解锁 vault 的命令都必须额外传入 `--totp-code <code>`，或在主密码之后通过 `--totp-stdin` 从 stdin 读取一次性验证码。

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

8. 备份、列出备份、导出明文 snapshot、导入 snapshot、恢复备份：

   ```bash
   ./build/password-manager-windows-core backup "test-password"
   ./build/password-manager-windows-core list-backups
   ./build/password-manager-windows-core export-snapshot "test-password"
   ./build/password-manager-windows-core import-snapshot "test-password" --in exports/vault-export-YYYYMMDD-HHMMSS.json
   ./build/password-manager-windows-core restore-backup "test-password" latest
   ```

   `backup` 默认写入 vault 同级 `backups/`，只保留最新 5 份 encrypted envelope；`export-snapshot` 默认写入同级 `exports/`，内容是明文 JSON，只应保存到受信任位置。

9. 执行远端对象同步。WebDAV 使用 `--endpoint`、`--object-key` 和可选 Basic Auth；S3 presigned 模式使用独立下载/上传 URL；腾讯云 COS 和阿里云 OSS 需要运行时传入 AK、SK、bucket，endpoint / appid / custom-url 按 provider 配置需要传入。同步状态默认写入 `<vault>.sync-state`，只保存远端指纹、本地 dirty flag 和同步版本，不保存 AK、SK、WebDAV 密码或主密码：

   生产环境建议将 WebDAV password、对象存储 SK 和 presigned URL 分别通过 `--remote-password-stdin`、`--sk-stdin` / `--secret-key-stdin`、`--download-url-stdin` / `--upload-url-stdin` 输入，避免同步凭据出现在 argv。

   ```bash
   ./build/password-manager-windows-core sync "test-password" \
     --provider webdav \
     --endpoint https://dav.example.com/remote.php/dav/files/me \
     --object-key vault.sync.json \
     --username me \
     --remote-password "app-password"

   ./build/password-manager-windows-core sync "test-password" \
     --provider s3-presigned \
     --download-url "https://storage.example.com/download-presigned" \
     --upload-url "https://storage.example.com/upload-presigned"

   ./build/password-manager-windows-core sync "test-password" \
     --provider tencent-cos \
     --ak "$TENCENT_SECRET_ID" \
     --sk "$TENCENT_SECRET_KEY" \
     --bucket password-manager \
     --endpoint cos.ap-shanghai.myqcloud.com \
     --appid "$TENCENT_APP_ID" \
     --object-key vault.sync.json

   ./build/password-manager-windows-core sync "test-password" \
     --provider aliyun-oss \
     --ak "$ALIYUN_ACCESS_KEY_ID" \
     --sk "$ALIYUN_ACCESS_KEY_SECRET" \
     --bucket password-manager \
     --endpoint oss-cn-hangzhou.aliyuncs.com \
     --object-key vault.sync.json
   ```

10. 确认 `vault-windows-native.envelope` 和 `backups/vault-*.json` 包含 salt、iterations、verifier、nonce、ciphertext、mac，但不包含分类名、username 或 password 等 vault 明文。

Windows 实机验证还需要覆盖：

1. `.exe` 启动并显示原生窗口。
2. 初始化、解锁、锁定。
3. credential/server/service CRUD。
4. 搜索、分类和标签。
5. TOTP 解锁。
6. GUI 中的导入导出、备份和恢复交互。
7. GUI 中的远端同步配置和执行。
8. 关闭进程和重启后的数据保留。
9. Windows 高 DPI、深色模式、键盘导航和屏幕阅读器基础可访问性。

### 发布构建

Visual Studio / MSBuild release build：

```powershell
msbuild PasswordManagerWindows.vcxproj /p:Configuration=Release /p:Platform=x64
```

发布前先运行本机 contract gate：

```bash
./scripts/verify_release.sh
```

该 release gate 会先构建并测试 portable shared core，再校验 `vcpkg.json`、`VcpkgEnableManifest`、`x64-windows` triplet、Release 运行库/安全选项、OpenSSL/libcurl 链接项、`PasswordManagerWindows.manifest`、`VERSIONINFO` 版本资源和 README 清单；它不替代 Windows 实机 MSBuild、签名或干净 VM 安装验证。

发布前需要：

1. 复核应用名称、版本号、公司名、图标和 manifest；当前 manifest 与 `VERSIONINFO` 版本资源已纳入本机 contract gate，正式图标仍需随安装器/商店素材补齐。
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

Release notes 只能描述已经验证的能力；当前不能把完整 GUI、GUI 同步入口、Windows Credential Manager 集成或 MSBuild 生产 libcurl 打包写成已发布能力。

### 发布检查清单

- [x] Windows 原生目录在 `apps/windows_native` 下创建。
- [x] README 提供中文和英文版本。
- [x] README 说明开发、发布构建、Windows 分发/上架步骤。
- [x] Win32 app skeleton 和 Visual Studio `.vcxproj` 已添加。
- [x] Windows/Linux 原生端共用 `apps/native_core`，避免 core 双写偏差。
- [x] `vcpkg.json` 声明 Visual Studio / MSBuild release 依赖 OpenSSL 和 libcurl。
- [x] 应用 manifest 和 `VERSIONINFO` 版本资源已配置，并纳入本机 release contract gate。
- [x] `scripts/verify_release.sh` 串联 portable shared core release binary 构建、CLI `self-test`、启用 `assert` 的 C++/CLI smoke 和 Windows release contract verifier。
- [x] `scripts/verify_release_contract.py` 会验证 Release|x64、vcpkg manifest、shared core 引用、运行库/安全选项、OpenSSL/libcurl 链接合同、应用 manifest 和 `VERSIONINFO` 版本资源。
- [x] Portable core 使用 PBKDF2-SHA256 + AES-256-GCM。
- [x] C++ 测试覆盖加密 envelope、错误密码拒绝、snapshot 反序列化、encrypted vault 文件读回、TOTP、entry 过滤、集合重建和 version-vector merge。
- [x] portable smoke-test CLI 可在当前机器构建。
- [x] Windows/Linux 共用 terminal-native CLI，支持加密 vault 初始化、stdin 主密码输入、TOTP vault 解锁强制校验、状态读取、分类模板持久化、条目新增/搜索/查看/软删除。
- [x] Windows portable CLI release gate 验证字段关联五态安全展示、默认及 `--show-secret` 不泄露原始关联/未知/孤儿值或目标秘密、安全搜索投影，以及 `export-snapshot` 无损保真。
- [x] Windows/Linux 共用 terminal-native CLI 支持 WebDAV、S3 presigned URL、腾讯云 COS、阿里云 OSS 远端对象同步。
- [ ] 在 Windows 10/11 上用 Visual Studio/MSBuild 构建 `.exe`。
- [ ] 完整 Win32/WinUI 3/WPF UI 完成。
- [ ] 完整 CRUD、导入导出、备份恢复 GUI 完成。
- [ ] Windows Credential Manager / DPAPI / CNG 密钥保护完成。
- [ ] GUI 远端同步入口完成。
- [ ] Windows 实机 MSBuild 构建验证和干净 Windows VM 运行时依赖验证完成。
- [ ] `.exe` 代码签名完成。
- [ ] MSIX/MSI/winget 至少一种安装包完成安装验证。
- [ ] Microsoft Store 或企业分发审核通过。

---

## English

This directory contains the native Windows application target, used to build Windows-native parity incrementally.

### Scope

- The current slice is a C++17 + Win32 native Windows starting point.
- `src/win32_app.cpp` provides a minimal Win32 window skeleton for future real UI work.
- `PasswordManagerWindows.vcxproj` provides a Visual Studio / MSBuild project scaffold with a vcpkg manifest, Release runtime/security settings, and OpenSSL/libcurl link contract.
- The portable core uses the shared `apps/native_core` C++17 + OpenSSL path and can currently be built and tested locally with clang.
- Testable core is implemented: PBKDF2-SHA256, AES-256-GCM encrypted vault envelope, TOTP, entry model, search/filtering, category/tag collection rebuilding, JSON snapshot serialization/deserialization, encrypted vault file read/write, and version-vector merge.
- The CLI supports initialization, `--password-stdin` master password input, TOTP-protected vault enforcement, unlock status checks, persisted category templates, credential/server/service entry add, search/list, single-entry view, soft delete, local encrypted envelope backup/restore, plaintext snapshot export/import, TOTP, WebDAV / S3 presigned URL / Tencent COS / Aliyun OSS remote object sync, and self-test through shared `apps/native_core/src/vault_cli.cpp`.
- The shared C++ core losslessly preserves entry references and provides five-state resolution, lifecycle propagation, safe search projection, a pure copy-import ID remapping helper, and sync conflict-preservation coverage. CLI search uses only successfully resolved target labels/categories and suppresses raw reference IDs, target secrets, unknown field values, and orphaned binding values. `show-entry` provides five-state safe reference display as `empty`, `resolved: <label> - <category>`, `missing`, `deleted`, or `categoryMismatch`; this remains safe with `--show-secret`, which only controls the selected entry's own secret. `export-snapshot` is the lossless plaintext boundary and intentionally retains raw reference IDs and unknown/orphan values, so its output is sensitive vault data. Tags remain unchanged; reference editing and a scoped-copy CLI flow are still outside this slice. See `../../docs/FIELD_REFERENCE_CONTRACT.md` for the format and rollout order.
- Full Win32/WinUI 3/WPF GUI, Windows Credential Manager / DPAPI integration, GUI sync entry points, Windows-host MSBuild validation, and clean Windows VM runtime dependency validation are not implemented yet.

### Directory Layout

- `PasswordManagerWindows.vcxproj`: Visual Studio C++ Win32 app project skeleton with shared `vault_core` / `vault_cli` source references.
- `vcpkg.json`: Visual Studio / MSBuild release dependency manifest for OpenSSL and libcurl.
- `scripts/verify_release_contract.py`: locally runnable Windows release contract verifier for `.vcxproj` / `vcpkg.json` / README.
- `Makefile`: build and test entry point for the portable core outside Windows.
- `src/win32_app.cpp`: minimal Win32 window app.
- `src/main.cpp`: Windows native CLI entrypoint.
- `../native_core/src/vault_core.hpp`: shared core types and API.
- `../native_core/src/vault_core.cpp`: shared crypto, TOTP, entry, merge, category template, and object storage signing implementation.
- `../native_core/src/vault_cli.cpp`: shared Windows/Linux terminal-native CLI.
- `../native_core/tests/vault_core_tests.cpp`: shared Windows/Linux C++ core tests.
- `../native_core/tests/vault_cli_smoke.sh`: runs the current platform CLI artifact through five-state reference display, search suppression, and lossless `export-snapshot` checks.

### Requirements

Windows device development:

- Windows 10/11.
- Visual Studio 2022 with the Desktop development with C++ workload.
- Windows 10/11 SDK.
- vcpkg integrated with Visual Studio / MSBuild; the project restores OpenSSL 3 and libcurl through `VcpkgEnableManifest` and the `x64-windows` triplet.
- WiX Toolset or MSIX Packaging Tool for installers.

Current local verification:

- clang++.
- GNU Make.
- OpenSSL 3 headers/libs, defaulting to `/opt/homebrew/opt/openssl@3`.
- libcurl headers/libs discoverable by the Makefile through `curl-config`.
- Python 3 for the Windows release contract verifier.

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

Verify the Visual Studio / MSBuild release contract on the current machine; this does not claim that a Windows `.exe` has been built:

```bash
python3 scripts/verify_release_contract.py
```

Run the locally verifiable Windows native release gate:

```bash
./scripts/verify_release.sh
```

The script builds the portable shared core release binary and runs CLI `self-test`, then runs assertion-enabled C++ core tests, shared CLI smoke including the safe reference display/search and lossless export contract, and the Visual Studio / MSBuild release contract verifier. It does not replace Windows-host MSBuild, signing, or clean-VM installation validation.

### Local Feature Verification

Current portable core verification:

1. Run `make test`.
2. Run self-test:

   ```bash
   ./build/password-manager-windows-core self-test
   ```

   On production or shared machines, prefer stdin password input so the master password does not enter process argv or shell history:

   ```bash
   printf '%s\n' "$PM_PASSWORD" | ./build/password-manager-windows-core status --password-stdin
   ```

   If the vault has TOTP enabled, every command that unlocks the vault must also provide `--totp-code <code>` or read the one-time code from stdin with `--totp-stdin` after any stdin password.

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

6. Run remote object sync. WebDAV uses `--endpoint`, `--object-key`, and optional Basic Auth; S3 presigned mode uses explicit download/upload URLs; Tencent COS and Aliyun OSS require AK, SK, and bucket at runtime, with endpoint, appid, or custom-url provided as needed. Sync state defaults to `<vault>.sync-state` and stores only remote fingerprints, local dirty state, and sync version data, not AK, SK, WebDAV passwords, or the master password:

   In production, prefer `--remote-password-stdin` for WebDAV passwords, `--sk-stdin` / `--secret-key-stdin` for object-storage secret keys, and `--download-url-stdin` / `--upload-url-stdin` for presigned URLs so sync credentials do not appear in argv.

   ```bash
   ./build/password-manager-windows-core sync "test-password" \
     --provider webdav \
     --endpoint https://dav.example.com/remote.php/dav/files/me \
     --object-key vault.sync.json \
     --username me \
     --remote-password "app-password"

   ./build/password-manager-windows-core sync "test-password" \
     --provider s3-presigned \
     --download-url "https://storage.example.com/download-presigned" \
     --upload-url "https://storage.example.com/upload-presigned"

   ./build/password-manager-windows-core sync "test-password" \
     --provider tencent-cos \
     --ak "$TENCENT_SECRET_ID" \
     --sk "$TENCENT_SECRET_KEY" \
     --bucket password-manager \
     --endpoint cos.ap-shanghai.myqcloud.com \
     --appid "$TENCENT_APP_ID" \
     --object-key vault.sync.json

   ./build/password-manager-windows-core sync "test-password" \
     --provider aliyun-oss \
     --ak "$ALIYUN_ACCESS_KEY_ID" \
     --sk "$ALIYUN_ACCESS_KEY_SECRET" \
     --bucket password-manager \
     --endpoint oss-cn-hangzhou.aliyuncs.com \
     --object-key vault.sync.json
   ```

7. Confirm `vault-windows-native.envelope` contains salt, iterations, verifier, nonce, ciphertext, and mac, but does not contain the sample entry plaintext username or password.

Windows device validation still needs:

1. `.exe` launches and shows a native window.
2. Setup, unlock, and lock.
3. Credential/server/service CRUD.
4. Search, categories, and tags.
5. TOTP unlock.
6. Import/export, backup, and restore.
7. GUI remote sync configuration and execution.
8. Data retention after process close and relaunch.
9. High DPI, dark mode, keyboard navigation, and baseline screen-reader accessibility.

### Release Build

Visual Studio / MSBuild release build:

```powershell
msbuild PasswordManagerWindows.vcxproj /p:Configuration=Release /p:Platform=x64
```

Run the local contract gate before release:

```bash
./scripts/verify_release.sh
```

The release gate first builds and tests the portable shared core, then verifies `vcpkg.json`, `VcpkgEnableManifest`, the `x64-windows` triplet, Release runtime/security settings, OpenSSL/libcurl link entries, `PasswordManagerWindows.manifest`, `VERSIONINFO` version resources, and the README checklist. It does not replace Windows-host MSBuild, signing, or clean-VM installation validation.

Before release:

1. Review the app name, version, company name, icon, and manifest. The manifest and `VERSIONINFO` version resources are now covered by the local contract gate; the final icon still belongs with installer/store assets.
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

Release notes must only describe verified capabilities. Do not list full GUI, GUI sync entry points, Windows Credential Manager integration, or MSBuild production libcurl packaging as shipped yet.

### Release Checklist

- [x] Native Windows directory is created under `apps/windows_native`.
- [x] README provides Chinese and English versions.
- [x] README documents development, release build, Windows distribution/submission steps.
- [x] Win32 app skeleton and Visual Studio `.vcxproj` are added.
- [x] `vcpkg.json` declares OpenSSL and libcurl for Visual Studio / MSBuild release dependency restoration.
- [x] The application manifest and `VERSIONINFO` version resources are configured and covered by the local release contract gate.
- [x] `scripts/verify_release.sh` chains the portable shared core release binary build, CLI `self-test`, assertion-enabled C++/CLI smoke coverage, and Windows release contract verifier.
- [x] `scripts/verify_release_contract.py` verifies Release|x64, vcpkg manifest mode, shared core references, runtime/security settings, OpenSSL/libcurl link contract, the application manifest, and `VERSIONINFO` version resources.
- [x] Portable core uses PBKDF2-SHA256 + AES-256-GCM.
- [x] C++ tests cover encrypted envelope, wrong-password rejection, TOTP, entry filtering, collection rebuilding, and version-vector merge.
- [x] Portable smoke-test CLI builds on the current machine.
- [x] Shared Windows/Linux terminal-native CLI supports encrypted vault initialization, stdin master password input, TOTP-protected vault enforcement, status reads, category template persistence, and entry add/search/view/soft-delete.
- [x] The Windows portable CLI release gate verifies five-state safe reference display, no raw reference/unknown/orphan values or target secrets in default and `--show-secret` output, safe search projection, and lossless `export-snapshot` persistence.
- [x] Shared Windows/Linux terminal-native CLI supports WebDAV, S3 presigned URL, Tencent COS, and Aliyun OSS remote object sync.
- [ ] Build `.exe` on Windows 10/11 with Visual Studio/MSBuild.
- [ ] Full Win32/WinUI 3/WPF UI is complete.
- [ ] Full CRUD, import/export, and backup/restore GUI is complete.
- [ ] Windows Credential Manager / DPAPI / CNG key protection is complete.
- [ ] GUI remote sync entry points are complete.
- [ ] Windows-host MSBuild validation and clean Windows VM runtime dependency validation are complete.
- [ ] `.exe` code signing is complete.
- [ ] At least one MSIX/MSI/winget installer is install-tested.
- [ ] Microsoft Store or enterprise distribution review is approved.
