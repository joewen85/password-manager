# Password Manager Linux Native

## 中文

该目录包含 Linux 原生重构目标。它与 `apps/flutter_app` 明确隔离，用于在不改动现有 Flutter Linux 实现和既有功能行为的前提下，逐步补齐 Linux 原生端能力。

### 范围

- 当前切片是 C++17 + OpenSSL 的 Linux terminal-native 起点。
- 已实现可测试核心：PBKDF2-SHA256、AES-256-GCM encrypted vault envelope、TOTP、entry model、搜索/过滤、分类/标签集合、JSON snapshot 序列化、version-vector merge。
- CLI 入口支持 smoke-test 初始化 encrypted envelope、TOTP 生成和 `self-test`。
- 当前尚未实现 GTK/Qt/libadwaita 图形界面，也尚未实现完整交互式 CRUD 和真实 WebDAV/S3 网络同步。
- 当前在 macOS 上用 clang + Homebrew OpenSSL 验证核心逻辑；发布前仍需在 Linux 发行版上用系统 OpenSSL 重新构建和回归。

### 目录说明

- `Makefile`: 构建和测试入口。
- `src/vault_core.hpp`: 核心类型和 API。
- `src/vault_core.cpp`: crypto、TOTP、entry、merge 实现。
- `src/main.cpp`: terminal-native smoke-test CLI。
- `tests/vault_core_tests.cpp`: C++ 核心测试。

### 环境要求

- Linux 发布构建：GCC 或 Clang、GNU Make、OpenSSL 3 development headers。
- 本机验证环境：macOS clang + `/opt/homebrew/opt/openssl@3`。

Linux 安装依赖示例：

```bash
# Debian / Ubuntu
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev

# Fedora
sudo dnf install -y gcc-c++ make openssl-devel

# Arch
sudo pacman -S --needed base-devel openssl
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

### 本地功能验证

1. 运行 `make test`。
2. 运行 self-test：

   ```bash
   ./build/password-manager-linux self-test
   ```

3. 生成 encrypted envelope smoke-test 文件：

   ```bash
   ./build/password-manager-linux init "test-password"
   ```

4. 确认 `vault-linux-native.envelope` 包含 salt、iterations、verifier、nonce、ciphertext、mac，但不包含示例条目的明文 username 或 password。
5. 生成 RFC 6238 TOTP fixture：

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

### Linux 分发 / 上架

发布前需要在目标发行版上重新构建，并选择合适渠道：

1. `.deb`：
   - 准备 `DEBIAN/control`、安装路径、desktop file、icon、license。
   - 使用 `dpkg-deb --build` 生成包。
   - 在干净 Ubuntu/Debian VM 中安装测试。
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

Release notes 只能描述已经验证的能力；当前不能把 GUI、真实远端同步、系统 keyring 集成写成已发布能力。

### 发布检查清单

- [x] Linux 原生目录在 `apps/linux_native` 下创建。
- [x] README 提供中文和英文版本。
- [x] README 说明开发、发布构建、Linux 分发/上架步骤。
- [x] 核心使用 PBKDF2-SHA256 + AES-256-GCM。
- [x] C++ 测试覆盖加密 envelope、错误密码拒绝、TOTP、entry 过滤、集合重建和 version-vector merge。
- [x] terminal-native smoke-test CLI 可构建。
- [ ] 在真实 Linux 发行版上构建和测试。
- [ ] GTK/Qt/libadwaita GUI 完成。
- [ ] 完整 CRUD、导入导出、备份恢复 UI 完成。
- [ ] 真实 WebDAV/S3 远端同步完成。
- [ ] Linux secret service / keyring 集成完成。
- [ ] `.deb`、`.rpm`、AppImage、Flatpak 或 Snap 至少一种发布包完成安装验证。
- [ ] Flathub/Snap Store 或发行版仓库发布审核通过。

---

## English

This directory contains the native Linux rewrite target. It is intentionally separate from `apps/flutter_app` so the existing Flutter Linux implementation remains untouched while native Linux parity is built incrementally.

### Scope

- The current slice is a C++17 + OpenSSL Linux terminal-native starting point.
- Testable core is implemented: PBKDF2-SHA256, AES-256-GCM encrypted vault envelope, TOTP, entry model, search/filtering, category/tag collection rebuilding, JSON snapshot serialization, and version-vector merge.
- The CLI entry point supports smoke-test encrypted envelope initialization, TOTP generation, and `self-test`.
- GTK/Qt/libadwaita GUI, full interactive CRUD, and real WebDAV/S3 network sync are not implemented yet.
- The current verification runs on macOS with clang + Homebrew OpenSSL. Release must be rebuilt and regressed on Linux distributions with system OpenSSL.

### Directory Layout

- `Makefile`: build and test entry point.
- `src/vault_core.hpp`: core types and API.
- `src/vault_core.cpp`: crypto, TOTP, entry, and merge implementation.
- `src/main.cpp`: terminal-native smoke-test CLI.
- `tests/vault_core_tests.cpp`: C++ core tests.

### Requirements

- Linux release build: GCC or Clang, GNU Make, OpenSSL 3 development headers.
- Local verification here: macOS clang + `/opt/homebrew/opt/openssl@3`.

Linux dependency examples:

```bash
# Debian / Ubuntu
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev

# Fedora
sudo dnf install -y gcc-c++ make openssl-devel

# Arch
sudo pacman -S --needed base-devel openssl
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

### Local Feature Verification

1. Run `make test`.
2. Run self-test:

   ```bash
   ./build/password-manager-linux self-test
   ```

3. Generate an encrypted envelope smoke-test file:

   ```bash
   ./build/password-manager-linux init "test-password"
   ```

4. Confirm `vault-linux-native.envelope` contains salt, iterations, verifier, nonce, ciphertext, and mac, but does not contain the sample entry plaintext username or password.
5. Generate the RFC 6238 TOTP fixture:

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

### Linux Distribution / Submission

Before release, rebuild on target distributions and choose a channel:

1. `.deb`:
   - Prepare `DEBIAN/control`, install paths, desktop file, icon, and license.
   - Use `dpkg-deb --build`.
   - Install-test in a clean Ubuntu/Debian VM.
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

Release notes must only describe verified capabilities. Do not list GUI, real remote sync, or system keyring integration as shipped yet.

### Release Checklist

- [x] Native Linux directory is created under `apps/linux_native`.
- [x] README provides Chinese and English versions.
- [x] README documents development, release build, Linux distribution/submission steps.
- [x] Core uses PBKDF2-SHA256 + AES-256-GCM.
- [x] C++ tests cover encrypted envelope, wrong-password rejection, TOTP, entry filtering, collection rebuilding, and version-vector merge.
- [x] Terminal-native smoke-test CLI builds.
- [ ] Build and test on a real Linux distribution.
- [ ] GTK/Qt/libadwaita GUI is complete.
- [ ] Full CRUD, import/export, and backup/restore UI are complete.
- [ ] Real WebDAV/S3 remote sync is complete.
- [ ] Linux secret service / keyring integration is complete.
- [ ] At least one `.deb`, `.rpm`, AppImage, Flatpak, or Snap package is install-tested.
- [ ] Flathub/Snap Store or distribution repository review is approved.
