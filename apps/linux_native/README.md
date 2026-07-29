# Password Manager Linux Native

## 中文

该目录包含 Linux 原生应用，用于逐步补齐 Linux 端原生能力。

### 范围

- 当前切片是 C++17 + OpenSSL 的 Linux terminal-native 起点，核心逻辑来自 `apps/native_core`。
- 已实现可测试核心：PBKDF2-SHA256、AES-256-GCM encrypted vault envelope、TOTP、entry model、搜索/过滤、分类/标签集合、JSON snapshot 序列化/反序列化、encrypted vault 文件读写、version-vector merge。
- CLI 入口支持初始化、`--password-stdin` 主密码输入、TOTP vault 解锁强制校验、解锁状态检查、分类模板持久化、credential/server/service 条目新增、搜索列表、单条查看、软删除、本地 encrypted envelope 备份/恢复、明文 snapshot 导出/导入、TOTP 生成、WebDAV / S3 presigned URL / 腾讯云 COS / 阿里云 OSS 远端对象同步和 `self-test`，Windows/Linux 共用 `apps/native_core/src/vault_cli.cpp`。
- 共享 C++ core 已无损保留字段关联契约，并提供五态解析、生命周期传播、安全搜索投影、纯 copy-import ID 重映射 helper 和同步冲突保真测试。CLI 搜索只使用成功解析目标的名称/分类，不索引原始引用 ID、目标秘密、未知字段值或孤儿绑定值；`show-entry` 将引用安全展示为 `empty`、`resolved: <名称> - <分类>`、`missing`、`deleted` 或 `categoryMismatch`，即使传入 `--show-secret` 也不会泄露上述原值或目标秘密。`export-snapshot` 是用于无损往返的敏感明文数据边界，会保留原始引用 ID 和未知/孤儿值。标签职责不变，CLI 已支持在创建来源模板字段时配置 `fieldReference` 并在创建条目时选择目标条目；旧 `entryReference` 编辑和 scoped-copy 导入流程仍未提供，格式与上线顺序见 `../../docs/FIELD_REFERENCE_CONTRACT.md`。
- 共享 core 已完成 `fieldReference` 九态单跳解析、目标字段生命周期保护、分类改名传播、安全搜索投影、copy-import 条目 ID 重映射和同步冲突保真；旧数据空字段 ID 名称回退与非空 ID 精确匹配规则在各端一致。P12 `show-entry` 已提供九态详情，只有 `resolved` 会在显式解锁详情中显示配置的目标文本字段值；原始 ID、目标秘密、无关字段和非成功态目标值始终隐藏，搜索也不索引目标字段值。
- 当前尚未实现 GTK/Qt/libadwaita 图形界面、GUI CRUD 和 GUI 同步入口。
- 当前在 macOS 上用 clang + Homebrew OpenSSL 验证核心逻辑；同时提供 Docker 化 Ubuntu release gate，可在真实 Linux userspace 中使用系统 OpenSSL/libcurl 重新构建、跑完整 core/CLI smoke，并构建/安装/卸载 CLI `.deb` 包。

### 目录说明

- `Makefile`: 构建和测试入口。
- `packaging/deb`: Debian package metadata for the terminal-native CLI。
- `scripts/package_deb.sh`: 从已构建 CLI 生成 `.deb` 包。
- `scripts/verify_install_deb.sh`: 安装、运行、卸载 `.deb` 包的验证脚本。
- `src/main.cpp`: Linux native CLI entrypoint。
- `../native_core/src/vault_core.hpp`: Windows/Linux 共享核心类型和 API。
- `../native_core/src/vault_core.cpp`: 共享 crypto、TOTP、entry、merge、分类模板和对象存储签名实现。
- `../native_core/src/vault_cli.cpp`: Windows/Linux 共享 terminal-native CLI。
- `../native_core/tests/vault_core_tests.cpp`: Windows/Linux 共用 C++ 核心测试。
- `../native_core/tests/vault_cli_smoke.sh`: 使用当前平台 CLI 产物验证旧条目关联五态、字段关联九态安全展示、搜索抑制和 `export-snapshot` 无损保真。

### 环境要求

- Linux 发布构建：GCC 或 Clang、GNU Make、OpenSSL 3 development headers、libcurl development headers/library。
- 本机验证环境：macOS clang + `/opt/homebrew/opt/openssl@3`。
- Python 3，用于共享 CLI smoke 中的字段关联 JSON 展示与无损导出断言。

Linux 安装依赖示例：

```bash
# Debian / Ubuntu
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev libcurl4-openssl-dev

# Fedora
sudo dnf install -y gcc-c++ make openssl-devel libcurl-devel

# Arch
sudo pacman -S --needed base-devel openssl curl
```

### 开发

构建 CLI：

```bash
make
```

运行测试：

```bash
make test
```

清理：

```bash
make clean
```

如果 OpenSSL 安装在非默认路径：

```bash
make OPENSSL_PREFIX=/usr
```

在 Ubuntu 容器中执行 Linux release gate：

```bash
./scripts/verify_release_docker.sh
```

该脚本会把 `apps/linux_native`、`apps/native_core` 与共享 `fixtures` 只读挂载进容器，将源码复制到容器内临时工作区，然后安装发行版 OpenSSL/libcurl 开发包，执行 release binary 构建、ELF/动态库检查、CLI `self-test` 和启用 `assert` 的 `make test`。`make test` 会用 Linux CLI 产物验证旧条目关联五态和字段关联九态安全展示、默认及 `--show-secret` 均不泄露原始关联值或目标秘密，并确认 `export-snapshot` 仍无损保留。可通过 `LINUX_RELEASE_DOCKER_IMAGE` 覆盖发行版镜像。
在 apt-based 镜像中，它还会执行 `make package-deb`，安装生成的 `.deb`，从 `/usr/bin/password-manager-linux` 运行 `self-test`，再卸载包确认命令被移除。

运行当前机器可验证的 Linux native release gate：

```bash
./scripts/verify_release.sh
```

该脚本会先构建 release binary 并执行 CLI `self-test`，再执行启用 `assert` 的 C++ core tests 和共享 CLI smoke，包括字段关联安全展示/搜索与无损导出合同，并检查当前宿主机 binary 与 OpenSSL/libcurl 的链接。若需要同时执行真实 Linux userspace 和 `.deb` 安装/卸载验证：

```bash
./scripts/verify_release.sh --docker
```

### 本地功能验证

1. 运行 `make test`。
2. 运行 self-test：

   ```bash
   ./build/password-manager-linux self-test
   ```

   生产或多人机器上建议用 stdin 传入主密码，避免主密码进入进程 argv 或 shell history：

   ```bash
   printf '%s\n' "$PM_PASSWORD" | ./build/password-manager-linux status --password-stdin
   ```

   如果 vault 启用了 TOTP，所有解锁 vault 的命令都必须额外传入 `--totp-code <code>`，或在主密码之后通过 `--totp-stdin` 从 stdin 读取一次性验证码。

3. 初始化 encrypted vault 文件：

   ```bash
   ./build/password-manager-linux init "test-password"
   ```

4. 解锁并查看 vault 状态：

   ```bash
   ./build/password-manager-linux status "test-password"
   ```

5. 添加分类模板并确认能再次解锁读回：

   ```bash
   ./build/password-manager-linux add-category "test-password" Infra --shortcut server --field Owner
   ./build/password-manager-linux status "test-password"
   ```

   字段到字段关联必须在创建来源模板字段的同一命令中设置。跨分类目标必须先存在；同分类目标文本字段可在同一命令用 `--field` 创建。参数使用人类可读名称，持久化时自动写入目标字段稳定 ID：

   ```bash
   ./build/password-manager-linux add-category "test-password" Servers \
     --field Email --field-reference "Owner Email" Servers Email
   ./build/password-manager-linux add-entry "test-password" \
     --label "Production Account" --category Servers --field Email=ops@example.com
   ./build/password-manager-linux add-entry "test-password" \
     --label "Production Server" --category Servers \
     --field-reference "Owner Email" "Production Account"
   ```

   条目目标可使用精确 ID，或使用目标分类内唯一的条目名称。命令会写入来源 `templateFieldId` 和目标条目 ID；普通 `--field` 与分类中的 text 模板同名时也会绑定其稳定 ID，真正的临时字段仍保持空绑定。命令拒绝缺失/非文本目标字段、直接自引用、失效目标和歧义名称，不需要先创建文本字段再改型。该能力仅增加现有加密 JSON 属性，不存在数据库 schema，因此不需要数据库迁移文件；旧快照由 decoder 默认值兼容。

6. 添加、搜索、查看和软删除条目。列表和查看默认隐藏 secret，只有显式传入 `--show-secret` 才显示：

   ```bash
   ./build/password-manager-linux add-entry "test-password" \
     --label "Billing API" \
     --type service \
     --username svc-user \
     --secret svc-secret \
     --category Services \
     --tag prod \
     --field Owner=Platform
   ./build/password-manager-linux list "test-password" --query Owner:Platform
   ./build/password-manager-linux show-entry "test-password" "<entry-id>"
   ./build/password-manager-linux delete-entry "test-password" "<entry-id>"
   ```

7. 备份、列出备份、导出明文 snapshot、导入 snapshot、恢复备份：

   ```bash
   ./build/password-manager-linux backup "test-password"
   ./build/password-manager-linux list-backups
   ./build/password-manager-linux export-snapshot "test-password"
   ./build/password-manager-linux import-snapshot "test-password" --in exports/vault-export-YYYYMMDD-HHMMSS.json
   ./build/password-manager-linux restore-backup "test-password" latest
   ```

   `backup` 默认写入 vault 同级 `backups/`，只保留最新 5 份 encrypted envelope；`export-snapshot` 默认写入同级 `exports/`，内容是明文 JSON，只应保存到受信任位置。

8. 执行远端对象同步。WebDAV 使用 `--endpoint`、`--object-key` 和可选 Basic Auth；S3 presigned 模式使用独立下载/上传 URL；腾讯云 COS 和阿里云 OSS 需要运行时传入 AK、SK、bucket，endpoint / appid / custom-url 按 provider 配置需要传入。同步状态默认写入 `<vault>.sync-state`，只保存远端指纹、本地 dirty flag 和同步版本，不保存 AK、SK、WebDAV 密码或主密码：

   生产环境建议将 WebDAV password、对象存储 SK 和 presigned URL 分别通过 `--remote-password-stdin`、`--sk-stdin` / `--secret-key-stdin`、`--download-url-stdin` / `--upload-url-stdin` 输入，避免同步凭据出现在 argv。

   ```bash
   ./build/password-manager-linux sync "test-password" \
     --provider webdav \
     --endpoint https://dav.example.com/remote.php/dav/files/me \
     --object-key vault.sync.json \
     --username me \
     --remote-password "app-password"

   ./build/password-manager-linux sync "test-password" \
     --provider s3-presigned \
     --download-url "https://storage.example.com/download-presigned" \
     --upload-url "https://storage.example.com/upload-presigned"

   ./build/password-manager-linux sync "test-password" \
     --provider tencent-cos \
     --ak "$TENCENT_SECRET_ID" \
     --sk "$TENCENT_SECRET_KEY" \
     --bucket password-manager \
     --endpoint cos.ap-shanghai.myqcloud.com \
     --appid "$TENCENT_APP_ID" \
     --object-key vault.sync.json

   ./build/password-manager-linux sync "test-password" \
     --provider aliyun-oss \
     --ak "$ALIYUN_ACCESS_KEY_ID" \
     --sk "$ALIYUN_ACCESS_KEY_SECRET" \
     --bucket password-manager \
     --endpoint oss-cn-hangzhou.aliyuncs.com \
     --object-key vault.sync.json
   ```

9. 确认 `vault-linux-native.envelope` 和 `backups/vault-*.json` 包含 salt、iterations、verifier、nonce、ciphertext、mac，但不包含分类名、username 或 password 等 vault 明文。
10. 生成 RFC 6238 TOTP fixture：

   ```bash
   ./build/password-manager-linux totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 59
   ```

   期望输出 `287082`。

### 发布构建

Linux 原生端后续建议分两层发布：

1. `password-manager-linux` terminal-native binary，用于 headless、运维和核心 smoke-test。
2. GTK/Qt/libadwaita GUI binary，用于桌面用户。

当前 CLI release 构建：

```bash
make clean
make CXXFLAGS="-std=c++17 -O2 -DNDEBUG"
strip build/password-manager-linux
```

生成 CLI `.deb` 包：

```bash
make package-deb PACKAGE_VERSION=0.1.0
```

产物生成在 `dist/password-manager-linux_<version>_<arch>.deb`。发布候选应在 Ubuntu/Debian 容器或干净 VM 中安装验证：

```bash
sudo ./scripts/verify_install_deb.sh dist/password-manager-linux_0.1.0_amd64.deb
```

发布候选必须先通过容器化 Linux release gate：

```bash
./scripts/verify_release.sh --docker
```

### Linux 分发 / 上架

发布前需要在目标发行版上重新构建，并选择合适渠道：

1. `.deb`：
   - CLI 包已提供 `packaging/deb/DEBIAN/control`、安装路径和 copyright metadata。
   - 使用 `make package-deb` 生成包。
   - Docker release gate 会在 Ubuntu 容器中安装、运行 `self-test` 并卸载 `.deb`。
   - GUI desktop file、icon、desktop launcher 和系统 keyring 集成仍需随 GUI 切片补齐。
2. `.rpm`：
   - 准备 spec file。
   - 使用 `rpmbuild -ba` 生成 rpm。
   - 在 Fedora/openSUSE/RHEL 兼容环境安装测试。
3. AppImage：
   - 准备 AppDir、desktop file、icon。
   - 使用 appimagetool 打包。
   - 在无开发依赖的干净发行版上运行测试。
4. Flatpak / Flathub：
   - 准备 manifest。
   - 明确 sandbox 权限，尤其是网络同步、文件导入导出、secret storage。
   - 在本地 flatpak-builder 验证后再提交 Flathub。
5. Snap：
   - 准备 `snapcraft.yaml`。
   - 最小化 plugs，声明 network、home/removable-media 等权限需求。
   - 通过 Snap Store review 后发布。
6. 企业内部仓库：
   - 将 `.deb` / `.rpm` 放入内部 apt/yum 仓库。
   - 记录签名 key、校验和、SBOM 和发布说明。

Release notes 只能描述已经验证的能力；当前不能把 GUI、GUI 同步入口、系统 keyring 集成写成已发布能力。

### 发布检查清单

- [x] Linux 原生目录在 `apps/linux_native` 下创建。
- [x] README 提供中文和英文版本。
- [x] README 说明开发、发布构建、Linux 分发/上架步骤。
- [x] Windows/Linux 原生端共用 `apps/native_core`，避免 core 双写偏差。
- [x] 核心使用 PBKDF2-SHA256 + AES-256-GCM。
- [x] C++ 测试覆盖加密 envelope、错误密码拒绝、snapshot 反序列化、encrypted vault 文件读回、TOTP、entry 过滤、集合重建和 version-vector merge。
- [x] terminal-native smoke-test CLI 可构建。
- [x] Windows/Linux 共用 terminal-native CLI，支持加密 vault 初始化、stdin 主密码输入、TOTP vault 解锁强制校验、状态读取、分类模板持久化、条目新增/搜索/查看/软删除。
- [x] Linux CLI release gate 验证旧条目关联五态和字段关联九态安全展示、默认及 `--show-secret` 不泄露原始关联/未知/孤儿值或目标秘密、安全搜索投影，以及 `export-snapshot` 无损保真。
- [x] Windows/Linux 共用 terminal-native CLI 支持 WebDAV、S3 presigned URL、腾讯云 COS、阿里云 OSS 远端对象同步。
- [x] `scripts/verify_release.sh` 串联 release binary 构建、CLI `self-test`、启用 `assert` 的 C++/CLI smoke 和宿主机 binary 依赖检查。
- [x] Ubuntu Docker release gate 可在真实 Linux userspace 中构建、测试并校验 ELF/动态库。
- [x] CLI `.deb` 包可构建，并在 Ubuntu Docker release gate 中完成安装、`self-test` 和卸载验证。
- [ ] GTK/Qt/libadwaita GUI 完成。
- [ ] 完整 CRUD、导入导出、备份恢复 GUI 完成。
- [ ] GUI 远端同步入口完成。
- [ ] Linux secret service / keyring 集成完成。
- [ ] GUI 桌面发布包完成安装验证。
- [ ] Flathub/Snap Store 或发行版仓库发布审核通过。

---

## English

This directory contains the native Linux application target, used to build Linux-native parity incrementally.

### Scope

- The current slice is a C++17 + OpenSSL Linux terminal-native starting point.
- Testable core is implemented in shared `apps/native_core`: PBKDF2-SHA256, AES-256-GCM encrypted vault envelope, TOTP, entry model, search/filtering, category/tag collection rebuilding, JSON snapshot serialization/deserialization, encrypted vault file read/write, and version-vector merge.
- The CLI entry point supports encrypted vault initialization, `--password-stdin` master password input, TOTP-protected vault enforcement, unlock status checks, persisted category templates, credential/server/service entry add, search/list, single-entry view, soft delete, local encrypted envelope backup/restore, plaintext snapshot export/import, TOTP generation, WebDAV / S3 presigned URL / Tencent COS / Aliyun OSS remote object sync, and `self-test`.
- The shared C++ core losslessly preserves entry references and provides five-state resolution, lifecycle propagation, safe search projection, a pure copy-import ID remapping helper, and sync conflict-preservation coverage. CLI search uses only successfully resolved target labels/categories and suppresses raw reference IDs, target secrets, unknown field values, and orphaned binding values. `show-entry` provides five-state safe reference display as `empty`, `resolved: <label> - <category>`, `missing`, `deleted`, or `categoryMismatch`; this remains safe with `--show-secret`, which only controls the selected entry's own secret. `export-snapshot` is the lossless plaintext boundary and intentionally retains raw reference IDs and unknown/orphan values, so its output is sensitive vault data. Tags remain unchanged. The CLI now creates `fieldReference` definitions with their source fields and binds them while creating entries; legacy `entryReference` editing and scoped-copy remain outside this slice. See `../../docs/FIELD_REFERENCE_CONTRACT.md` for the format and rollout order.
- The P12 shared CLI renders all nine `fieldReference` states through `show-entry`. Only `resolved` includes the configured target text field value at this explicit unlocked detail boundary; raw IDs, target secrets, unrelated fields, and non-resolved target values remain hidden, and CLI search never indexes the target field value.
- GTK/Qt/libadwaita GUI, GUI CRUD, and GUI sync entry points are not implemented yet.
- The current verification runs on macOS with clang + Homebrew OpenSSL. A Dockerized Ubuntu release gate is also available to rebuild with distribution OpenSSL/libcurl, run the full core/CLI smoke coverage, and build/install/uninstall the CLI `.deb` package in a real Linux userspace.

### Directory Layout

- `Makefile`: build and test entry point.
- `packaging/deb`: Debian package metadata for the terminal-native CLI.
- `scripts/package_deb.sh`: builds a `.deb` package from the compiled CLI.
- `scripts/verify_install_deb.sh`: installs, runs, and uninstalls a `.deb` package.
- `src/main.cpp`: Linux native CLI entrypoint.
- `../native_core/src/vault_core.hpp`: shared Windows/Linux core types and API.
- `../native_core/src/vault_core.cpp`: shared crypto, TOTP, entry, merge, category template, and object storage signing implementation.
- `../native_core/src/vault_cli.cpp`: shared Windows/Linux terminal-native CLI.
- `../native_core/tests/vault_core_tests.cpp`: shared Windows/Linux C++ core tests.
- `../native_core/tests/vault_cli_smoke.sh`: runs the current platform CLI artifact through legacy five-state and field-reference nine-state display, search suppression, and lossless `export-snapshot` checks.

### Requirements

- Linux release build: GCC or Clang, GNU Make, OpenSSL 3 development headers, libcurl development headers/library.
- Local verification here: macOS clang + `/opt/homebrew/opt/openssl@3`.
- Python 3 for the shared CLI smoke's field-reference JSON display and lossless export assertions.

Linux dependency examples:

```bash
# Debian / Ubuntu
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev libcurl4-openssl-dev

# Fedora
sudo dnf install -y gcc-c++ make openssl-devel libcurl-devel

# Arch
sudo pacman -S --needed base-devel openssl curl
```

### Develop

Build the CLI:

```bash
make
```

Run tests:

```bash
make test
```

Clean:

```bash
make clean
```

If OpenSSL is installed in a custom location:

```bash
make OPENSSL_PREFIX=/usr
```

Run the Linux release gate inside an Ubuntu container:

```bash
./scripts/verify_release_docker.sh
```

The script read-only mounts `apps/linux_native`, `apps/native_core`, and the shared `fixtures`, copies the source trees into a temporary container workspace, installs distribution OpenSSL/libcurl development packages, runs a release binary build, ELF/dependency checks, the CLI `self-test`, and assertion-enabled `make test`. The test gate runs the Linux CLI artifact through legacy five-state and field-reference nine-state safe display, default and `--show-secret` non-disclosure, and lossless `export-snapshot` checks. On apt-based images, it also runs `make package-deb`, installs the generated `.deb`, runs `self-test` from `/usr/bin/password-manager-linux`, and uninstalls the package. Override the distro image with `LINUX_RELEASE_DOCKER_IMAGE` when needed.

Run the Linux native release gate that is available on the current host:

```bash
./scripts/verify_release.sh
```

The script builds the release binary and runs CLI `self-test`, then runs assertion-enabled C++ core tests and shared CLI smoke, including the safe reference display/search and lossless export contract, and checks the current host binary links OpenSSL/libcurl. To also run real Linux userspace and `.deb` install/uninstall validation:

```bash
./scripts/verify_release.sh --docker
```

### Local Feature Verification

1. Run `make test`.
2. Run self-test:

   ```bash
   ./build/password-manager-linux self-test
   ```

   On production or shared machines, prefer stdin password input so the master password does not enter process argv or shell history:

   ```bash
   printf '%s\n' "$PM_PASSWORD" | ./build/password-manager-linux status --password-stdin
   ```

   If the vault has TOTP enabled, every command that unlocks the vault must also provide `--totp-code <code>` or read the one-time code from stdin with `--totp-stdin` after any stdin password.

3. Generate an encrypted envelope smoke-test file:

   ```bash
   ./build/password-manager-linux init "test-password"
   ```

   Create the field-reference definition with its source template field, then bind it while creating the source entry. Cross-category targets must already exist; a same-category target text field can be declared with `--field` in the same command. Category and field arguments are human-readable names; the persisted contract uses stable field and entry IDs:

   ```bash
   ./build/password-manager-linux add-category "test-password" Servers \
     --field Email --field-reference "Owner Email" Servers Email
   ./build/password-manager-linux add-entry "test-password" \
     --label "Production Account" --category Servers --field Email=ops@example.com
   ./build/password-manager-linux add-entry "test-password" \
     --label "Production Server" --category Servers \
     --field-reference "Owner Email" "Production Account"
   ```

   A target entry may be selected by exact ID or by a unique label in the configured target category. Matching text `--field` values store the template field's stable ID, while genuinely ad-hoc fields keep an empty binding. Missing or non-text target fields, direct self-reference, unavailable targets, and ambiguous labels are rejected before saving. These are additive encrypted-JSON properties; there is no database schema or migration file, and legacy snapshots use decoder defaults.

4. Add, search, view, and soft-delete an entry. List and view output hide secrets unless `--show-secret` is passed:

   ```bash
   ./build/password-manager-linux add-entry "test-password" \
     --label "Billing API" \
     --type service \
     --username svc-user \
     --secret svc-secret \
     --category Services \
     --tag prod \
     --field Owner=Platform
   ./build/password-manager-linux list "test-password" --query Owner:Platform
   ./build/password-manager-linux show-entry "test-password" "<entry-id>"
   ./build/password-manager-linux delete-entry "test-password" "<entry-id>"
   ```

5. Run remote object sync. WebDAV uses `--endpoint`, `--object-key`, and optional Basic Auth; S3 presigned mode uses explicit download/upload URLs; Tencent COS and Aliyun OSS require AK, SK, and bucket at runtime, with endpoint, appid, or custom-url provided as needed. Sync state defaults to `<vault>.sync-state` and stores only remote fingerprints, local dirty state, and sync version data, not AK, SK, WebDAV passwords, or the master password:

   In production, prefer `--remote-password-stdin` for WebDAV passwords, `--sk-stdin` / `--secret-key-stdin` for object-storage secret keys, and `--download-url-stdin` / `--upload-url-stdin` for presigned URLs so sync credentials do not appear in argv.

   ```bash
   ./build/password-manager-linux sync "test-password" \
     --provider webdav \
     --endpoint https://dav.example.com/remote.php/dav/files/me \
     --object-key vault.sync.json \
     --username me \
     --remote-password "app-password"

   ./build/password-manager-linux sync "test-password" \
     --provider s3-presigned \
     --download-url "https://storage.example.com/download-presigned" \
     --upload-url "https://storage.example.com/upload-presigned"

   ./build/password-manager-linux sync "test-password" \
     --provider tencent-cos \
     --ak "$TENCENT_SECRET_ID" \
     --sk "$TENCENT_SECRET_KEY" \
     --bucket password-manager \
     --endpoint cos.ap-shanghai.myqcloud.com \
     --appid "$TENCENT_APP_ID" \
     --object-key vault.sync.json

   ./build/password-manager-linux sync "test-password" \
     --provider aliyun-oss \
     --ak "$ALIYUN_ACCESS_KEY_ID" \
     --sk "$ALIYUN_ACCESS_KEY_SECRET" \
     --bucket password-manager \
     --endpoint oss-cn-hangzhou.aliyuncs.com \
     --object-key vault.sync.json
   ```

6. Confirm `vault-linux-native.envelope` contains salt, iterations, verifier, nonce, ciphertext, and mac, but does not contain the sample entry plaintext username or password.
7. Generate the RFC 6238 TOTP fixture:

   ```bash
   ./build/password-manager-linux totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ 59
   ```

   Expected output: `287082`.

### Release Build

The Linux native target should eventually ship in two layers:

1. `password-manager-linux` terminal-native binary for headless, operations, and core smoke-test usage.
2. GTK/Qt/libadwaita GUI binary for desktop users.

Current CLI release build:

```bash
make clean
make CXXFLAGS="-std=c++17 -O2 -DNDEBUG"
strip build/password-manager-linux
```

Build the CLI `.deb` package:

```bash
make package-deb PACKAGE_VERSION=0.1.0
```

The artifact is written to `dist/password-manager-linux_<version>_<arch>.deb`. Release candidates should be install-tested in an Ubuntu/Debian container or clean VM:

```bash
sudo ./scripts/verify_install_deb.sh dist/password-manager-linux_0.1.0_amd64.deb
```

Release candidates must pass the containerized Linux release gate first:

```bash
./scripts/verify_release.sh --docker
```

### Linux Distribution / Submission

Before release, rebuild on target distributions and choose a channel:

1. `.deb`:
   - The CLI package provides `packaging/deb/DEBIAN/control`, install paths, and copyright metadata.
   - Build it with `make package-deb`.
   - The Docker release gate install-tests the `.deb` in an Ubuntu container, runs `self-test`, and uninstalls it.
   - GUI desktop files, icons, desktop launchers, and system keyring integration remain part of the GUI slice.
2. `.rpm`:
   - Prepare a spec file.
   - Use `rpmbuild -ba`.
   - Install-test on Fedora/openSUSE/RHEL-compatible environments.
3. AppImage:
   - Prepare AppDir, desktop file, and icon.
   - Package with appimagetool.
   - Run-test on a clean distribution without development dependencies.
4. Flatpak / Flathub:
   - Prepare a manifest.
   - Declare sandbox permissions for network sync, import/export file access, and secret storage.
   - Validate with flatpak-builder before submitting to Flathub.
5. Snap:
   - Prepare `snapcraft.yaml`.
   - Minimize plugs and declare network, home/removable-media, or other required permissions.
   - Publish after Snap Store review.
6. Internal enterprise repository:
   - Publish `.deb` / `.rpm` to internal apt/yum repositories.
   - Record signing key, checksums, SBOM, and release notes.

Release notes must only describe verified capabilities. Do not list GUI, GUI sync entry points, or system keyring integration as shipped yet.

### Release Checklist

- [x] Native Linux directory is created under `apps/linux_native`.
- [x] README provides Chinese and English versions.
- [x] README documents development, release build, Linux distribution/submission steps.
- [x] Core uses PBKDF2-SHA256 + AES-256-GCM.
- [x] C++ tests cover encrypted envelope, wrong-password rejection, TOTP, entry filtering, collection rebuilding, and version-vector merge.
- [x] Terminal-native smoke-test CLI builds.
- [x] Shared Windows/Linux terminal-native CLI supports encrypted vault initialization, stdin master password input, TOTP-protected vault enforcement, status reads, category template persistence, and entry add/search/view/soft-delete.
- [x] The Linux CLI release gate verifies legacy five-state and field-reference nine-state safe display, no raw reference/unknown/orphan values or target secrets in default and `--show-secret` output, safe search projection, and lossless `export-snapshot` persistence.
- [x] Shared Windows/Linux terminal-native CLI supports WebDAV, S3 presigned URL, Tencent COS, and Aliyun OSS remote object sync.
- [x] `scripts/verify_release.sh` chains the release binary build, CLI `self-test`, assertion-enabled C++/CLI smoke coverage, and host binary dependency inspection.
- [x] Ubuntu Docker release gate builds, tests, and verifies ELF/dependencies in a real Linux userspace.
- [x] CLI `.deb` package builds and is install-tested, self-tested, and uninstalled in the Ubuntu Docker release gate.
- [ ] GTK/Qt/libadwaita GUI is complete.
- [ ] Full CRUD, import/export, and backup/restore GUI is complete.
- [ ] GUI remote sync entry points are complete.
- [ ] Linux secret service / keyring integration is complete.
- [ ] GUI desktop package install validation is complete.
- [ ] Flathub/Snap Store or distribution repository review is approved.
