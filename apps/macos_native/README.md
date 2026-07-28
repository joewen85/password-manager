# Password Manager macOS Native

## 中文

该目录包含 macOS 原生应用，用于逐步补齐 macOS 端原生能力。

### 范围

- 使用 SwiftUI 和 macOS 26 SDK 构建 macOS 应用，包含 `WindowGroup`、原生侧边栏/列表/详情布局、菜单命令和 Settings 场景；搜索和工具栏采用 macOS 26 / Liquid Glass 时代的系统级 `NavigationSplitView`、`searchToolbarBehavior` 和 `ToolbarSpacer` 结构。
- 首个原生等价切片：初始化/解锁保险库、锁定保险库、条目列表、搜索/筛选、详情页 Overview/Fields 分段、详情字段复制/敏感字段显示、新增/编辑/删除 credential/server/service 条目、分类和标签字段、分类/标签管理、清空保险库数据、基于 TOTP 的二次验证解锁、Keychain + Touch ID 解锁、手动同步入口、本地加密备份、完整快照 JSON 导入/导出。
- 数据模型对齐现有共享契约：`credential`、`server`、`service`、PBKDF 元数据记录、AES-GCM payload 记录形状、软删除字段、删除 tombstone 时间戳、版本映射和 `updatedBy`。
- 字段关联已支持 Codable 模型、加密快照、同步和条目/分类导入导出的无损数据契约，并提供 `empty/resolved/missing/deleted/categoryMismatch` 纯领域解析及安全目标投影；标签职责不变。当前不提供关联编辑 UI，尚未接入搜索、生命周期传播或导入重映射，格式与上线顺序见 `../../docs/FIELD_REFERENCE_CONTRACT.md`。
- 已实现本地加密文件持久化。应用会将加密后的保险库 envelope 写入 Application Support，并使用 PBKDF2-SHA256 验证主密码、使用 AES-256-GCM 加密 payload。
- PBKDF2 默认参数与 Dart package 契约对齐：新建 macOS 原生保险库使用 600000 次迭代。
- 单元测试已覆盖 PBKDF2 verifier 确定性、AES-GCM 往返、篡改拒绝、TOTP 生成/验证、加密 envelope 持久化不泄露明文 secret、恢复最新加密备份、备份保留策略、同步合并数据层，以及解密由 `packages/crypto` 生成的多条目 fixture。
- 本地备份支持列出本机加密备份、恢复指定备份或最新备份，并自动保留最近 5 个备份文件。
- 同步合并数据层已对齐 Flutter 的 version-vector 规则：本地/远端支配、并发冲突、delete-vs-update tombstone、keep-both conflict copy 均有 Swift 测试覆盖。
- 远端同步 transport 层已对齐 Flutter 的 WebDAV 和 S3 presigned URL 行为：路径归一化、Basic Auth、JSON PUT、404/204 空远端、timeout/error 状态映射均有 Swift 测试覆盖。
- 同步设置模型已对齐 Flutter 字段契约：provider type、WebDAV/NAS WebDAV、S3 presigned URL、auto-sync、conflict strategy、sync master key、device id、revision、status 和 logs。原生 client factory 已可根据设置选择 WebDAV、NAS WebDAV 或 S3 presigned URL client。
- 同步设置保存会采用 repository 归一化后的 device id，确保内存态、普通配置文件和 Keychain secret 归属一致，与 Android store 行为一致。
- 同步引擎数据层已实现下载远端 payload、合并本地/远端快照、应用远端支配结果、上传新 revision、更新 sync revision/status/logs 的流程，并覆盖缺失远端、远端支配和并发冲突上传场景。
- 已新增 Keychain-backed sync secret store，并支持将 `webdavPassword`、presigned download/upload URL 从普通 `SyncSettings` 中 redacted 后再落盘；测试覆盖 redaction/apply-secrets、secret store 生命周期、普通配置文件无明文 secret，以及 `VaultStore` 重新加载同步设置。
- 同步设置 UI 已接入 `VaultStore` 和 Keychain secret store；provider 选择会只展示对应的 WebDAV/NAS WebDAV 或 S3 presigned URL 字段。同步中心已支持展示 provider/status/revision/last sync/last result、最近同步日志、手动同步和跳转同步设置。备份中心已支持创建备份、列出备份文件、显示大小/时间并在破坏性确认后恢复指定备份。手动同步入口已连接 `SyncClientFactory` 与 `VaultSyncEngine`，可上传本地 payload、应用合并结果并持久化 revision/status/logs。
- 侧边栏顶部已对齐 Android 首页状态摘要，展示条目数、分类数和同步状态；侧边栏工具栏已对齐 Android 首页快捷入口，可直接打开 Sync 和 Backups；Operations 已对齐 Android More Actions 的核心入口，可打开分类/标签管理、同步中心、备份中心、Export Center、Import Center、Clear Data，以及 macOS 原生 Settings 场景。Export Center 支持完整快照、选中条目、分类 JSON 和本地加密备份；Import Center 支持完整快照、条目/分类 JSON 和旧版 imports 目录流程，导入后会展示结果并在成功时重置当前筛选、搜索和选中状态。
- 已新增本地 `.app` 打包脚本、可重复生成的 `.icns` app icon、Developer ID notarization/staple 脚本、Info.plist 模板、privacy manifest 和最小 entitlements；默认可生成 ad-hoc + Hardened Runtime 本地验证包，Developer ID / Mac App Store 发布前仍需替换真实签名身份并完成 notarization 或上传验证。
- 生产发布前仍需完成真实 WebDAV/S3 端到端服务验证和发布前安全审查。

### 环境要求

- macOS 26 或更高版本。
- 带 SwiftPM 6.2、Swift 6.3 或更新 toolchain、macOS 26 SDK 的 Xcode。

检查本地工具链：

```bash
swift --version
```

### 开发

在当前目录运行：

```bash
swift run PasswordManagerMacOS
```

加密保险库文件存储在：

```text
~/Library/Application Support/PasswordManagerNative/vault.json
```

手动备份会把加密保险库 envelope 复制到：

```text
~/Library/Application Support/PasswordManagerNative/backups/
```

快照 JSON 导出默认使用 macOS 系统文件导出器保存到用户选择的位置；旧版本地导出流程仍会写入：

```text
~/Library/Application Support/PasswordManagerNative/exports/
```

快照 JSON 导入默认使用 macOS 系统文件选择器读取用户选择的 `.json` 文件；旧版本地导入流程仍会从以下目录读取：

```text
~/Library/Application Support/PasswordManagerNative/imports/
```

仅构建：

```bash
swift build
```

运行测试：

```bash
swift test
```

### 本地加密校验

修改持久化或加密代码后，使用以下流程校验：

1. 运行应用：

   ```bash
   swift run PasswordManagerMacOS
   ```

2. 使用主密码初始化保险库。
3. 至少新增一个 credential、一个 server 和一个 service 条目。
4. 退出并重新打开应用。
5. 验证错误密码无法解锁，正确密码可以恢复全部条目。
6. 在 Settings 中保存 Base32 TOTP shared secret，启用 2FA，锁定保险库，并验证缺失/错误验证码会被拒绝，当前 authenticator code 可以通过。
7. 执行手动备份，确认已创建 `backups/vault-*.json`，且文件包含加密 envelope 而非明文保险库字段。
8. 执行 JSON 导出，确认系统文件导出器保存的 `vault-export-*.json` 包含预期的完整快照 JSON。
9. 通过系统文件选择器选择快照 JSON 文件执行导入，并确认 entries/categories/tags/security settings 被导入快照替换；旧版 `imports/` 目录导入入口仍可用于本地验证。
10. 检查 `~/Library/Application Support/PasswordManagerNative/vault.json`，确认文件中不存在明文 label、username、password、token、server name 或 service name。
11. 提交前运行 `swift test` 和 `swift build`。

当前自动化测试覆盖：

- 固定 salt 和 iterations 下的 PBKDF2-SHA256 verifier 确定性。
- 正确密码验证和错误密码拒绝。
- 使用确定性 nonce 输入的 AES-GCM 加密/解密往返。
- authentication tag 被修改后的 AES-GCM 篡改拒绝。
- TOTP SHA1 code 生成和验证，参数与 Flutter auth package 相同：30 秒周期、6 位数字、+/-1 窗口。
- 手动备份会把加密保险库 envelope 复制为带时间戳的本地备份文件。
- 本地备份可以恢复最新加密备份，并自动保留最近 5 个备份文件。
- 完整快照 JSON 导出/导入可通过系统文件导出器/选择器往返，并保留本地 `exports/` 和 `imports/` 目录兼容流程。
- 完整快照 JSON 解码兼容 Android 导出的 `backupStatus` 字段和早期 Swift 快照使用的 `lastBackupStatus` 字段。
- 分类/标签管理覆盖创建、重复值拒绝、重命名和删除；删除分类会让已有条目变为未分类，删除标签会从已有条目移除该标签。
- 侧边栏工具栏的创建入口已对齐 Android 创建菜单，可直接新建条目、创建分类或创建标签。
- 条目列表空状态已对齐 Android：无条目时展示用途说明，并可直接从空状态新建条目。
- 条目列表筛选/搜索状态会随导入、恢复备份、清空数据、分类/标签变化和搜索变化自动校正，避免详情页停留在不可见或已不存在的条目上。
- 条目编辑器已对齐 Android 的分类/标签工作流：可从已有分类中选择、对已有标签多选，并可在编辑条目时快速创建分类或标签。
- Service 条目已支持编辑多个 service account；详情页会隐藏账号密码明细，并支持按需显示/复制。
- 详情页字段支持一键复制；密码和 secret 字段默认隐藏，可按需显示/隐藏并复制。
- 删除条目会记录删除 tombstone 时间戳；如果现有条目通过编辑恢复，会清除该时间戳，与 Android store 行为一致。
- 清空数据会要求主密码确认，并清空条目、分类、标签、2FA 设置和本地备份状态；Touch ID 解锁凭据会同步清除。
- 加密保险库 envelope 持久化不会在 `vault.json` 中泄露明文 label、username、password、access key 或 secret key。
- 与当前 Dart `packages/crypto` 生成 fixture 的跨实现兼容性。
- Dart fixture 覆盖 credential、server、service、service accounts、category/tag metadata、security settings、sync status、version vectors、`updatedBy` 和软删除 tombstone。
- 快照 JSON 解码兼容 Android `backupStatus` 和 Swift `lastBackupStatus` 字段，保证完整快照可跨端导入。
- WebDAV / S3 presigned URL 同步 transport 对齐 Flutter 的 URL 构造、认证 header、上传/下载 HTTP 方法和错误状态映射。
- 同步设置默认值、兼容解码、Flutter 字段名编码，以及 provider client factory 校验。
- 同步设置保存采用 repository 归一化后的 device id，空 device id 会立即生成并回写到 `VaultStore`。
- 同步引擎覆盖无远端时上传本地 payload、远端支配时只应用不上传、并发冲突时合并并上传下一 revision。
- 同步敏感字段 redaction、Keychain secret store 边界、普通配置文件无明文同步 secret、in-memory secret store 生命周期，以及 `VaultStore` 同步设置持久化。
- `VaultStore.syncNow(client:)` 会通过同步引擎上传本地快照、更新 revision/status/logs，并把结果写回加密保险库。

有意修改 Dart 加密契约后，重新生成 Dart crypto fixture：

```bash
cd ../../
dart pub get --directory packages/crypto
dart --packages=packages/crypto/.dart_tool/package_config.json \
  apps/macos_native/Tests/PasswordManagerMacOSTests/Fixtures/generate_dart_crypto_fixture.dart \
  > apps/macos_native/Tests/PasswordManagerMacOSTests/Fixtures/dart_crypto_fixture.json
cd apps/macos_native
swift test
```

### 发布构建

SwiftPM 可以生成 release executable：

```bash
swift build -c release
```

本目录也提供本地 `.app` 打包脚本：

```bash
./scripts/package_release.sh
```

打包脚本默认生成 `0.1.0 (1)`，其中 marketing version 会写入
`CFBundleShortVersionString`，build number 会写入 `CFBundleVersion`。版本号和构建号均要求为 1 到 3 段数字，例如 `1`、`1.0` 或 `1.0.0`。可用以下任一方式指定：

```bash
./scripts/package_release.sh 1.0.0 100
./scripts/package_release.sh --version 1.0.0 --build-number 100
MARKETING_VERSION=1.0.0 BUILD_NUMBER=100 ./scripts/package_release.sh
```

脚本会先复制 `ReleaseSupport/Info.plist` 作为模板，再写入实际的 app name、bundle id、icon name、marketing version 和 build number，因此发布包内的 bundle metadata 以本次打包参数为准。

本地发布候选验证可运行：

```bash
./scripts/package_smoke.sh
```

该脚本会运行 `swift test`、执行本地 `.app` 打包、校验 bundle metadata、SwiftPM resource bundle、`PrivacyInfo.xcprivacy`、`AppIcon.icns`、entitlements、codesign、zip 解压后的签名和资源，并启动打包后的 `.app` 做本机冒烟验证。这里需要注意，SwiftPM 生成的 `PasswordManagerMacOS_PasswordManagerMacOSApp.bundle` 必须放在 `.app` 根目录下，才能被 `Bundle.module` 正常找到。默认 ad-hoc 签名包仍会被 Gatekeeper 拒绝，这是未 notarize 的预期现象；Developer ID 分发需继续运行 notarization 流程。

默认输出：

```text
dist/release/Password Manager.app
dist/release/Password Manager.zip
```

脚本会执行：

1. `swift build -c release`。
2. 组装 `.app` bundle。
3. 从 `ReleaseSupport/Info.plist` 写入 bundle metadata。
4. 将 SwiftPM 生成的 `PasswordManagerMacOS_PasswordManagerMacOSApp.bundle` 复制到 `.app` 根目录，将 `ReleaseSupport/PrivacyInfo.xcprivacy` 复制到 bundle resources。
5. 通过 `scripts/generate_app_icon.swift` 生成 iconset，并用 `iconutil` 生成 `AppIcon.icns`。
6. 使用 `ReleaseSupport/PasswordManagerMacOS.entitlements` 签名。
7. 默认使用 ad-hoc identity `-` 并启用 Hardened Runtime，用于本地验证；提供 Developer ID identity 时会启用 secure timestamp，以满足 notarization 前置条件。
8. 执行 `codesign --verify --deep --strict`。
9. 如设置 `EXPECTED_TEAM_ID` 或 `EXPECTED_SIGNING_CERT_SHA256`，校验签名 TeamIdentifier 和 leaf signing certificate SHA-256 指纹。
10. 生成 notarization 可用的 zip 结构。

可通过环境变量覆盖更多发布 metadata 和签名身份：

```bash
APP_NAME="Password Manager" \
BUNDLE_ID=life.devops.passwordmanager \
MARKETING_VERSION=1.0.0 \
BUILD_NUMBER=100 \
ICON_NAME=AppIcon \
SIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
./scripts/package_release.sh
```

默认 `SIGN_IDENTITY=-` 会生成 ad-hoc 签名包，不携带 entitlements 文件并关闭 secure timestamp，仅用于本机验证。提供 `Developer ID Application: ...` identity 后，脚本会使用 `ReleaseSupport/PasswordManagerMacOS.entitlements`、启用 Hardened Runtime 和 secure timestamp，使产物满足 notarization 的前置签名要求。若需要改用其他 entitlements 文件，可通过 `ENTITLEMENTS=/path/to/file.plist` 覆盖。

Developer ID 发布前建议把签名证书固定到预期 Team ID 和证书指纹：

```bash
SIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
EXPECTED_TEAM_ID=TEAMID \
EXPECTED_SIGNING_CERT_SHA256=AA:BB:CC:... \
./scripts/package_release.sh
```

privacy manifest 当前声明不追踪、不列出 tracking domains、不声明数据收集或 required-reason API。若后续加入 telemetry、第三方 SDK、账号系统、剪贴板/磁盘空间/文件时间戳等 required-reason API 使用，需要同步更新 `ReleaseSupport/PrivacyInfo.xcprivacy` 和 App Store Connect 隐私信息。

app icon 当前由 `scripts/generate_app_icon.swift` 在打包时生成，输出到 `dist/release/AppIcon.iconset` 和 app bundle 内的 `Contents/Resources/AppIcon.icns`。`ReleaseSupport/Info.plist` 已声明 `CFBundleIconFile=AppIcon`。正式品牌视觉确定后，可以替换生成脚本或改为提交设计团队提供的 `.icns`，但发布包仍需保留 `CFBundleIconFile` 与 bundle resource 的一致性。

entitlements 当前最小化为 App Sandbox、outgoing network client、user-selected read-only/read-write file access。同步 secrets 使用默认 Keychain generic password item，不需要额外 Keychain access group；如果后续启用共享 Keychain group，再补 Keychain Sharing entitlement。

Developer ID notarization 可以使用本目录脚本执行：

```bash
NOTARY_KEYCHAIN_PROFILE=password-manager-notary \
./scripts/notarize_release.sh
```

也可以直接传入 Apple ID 凭据：

```bash
APPLE_ID=developer@example.com \
TEAM_ID=ABCDE12345 \
APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx \
./scripts/notarize_release.sh
```

脚本会拒绝 ad-hoc 签名的 app，只接受 `Developer ID Application:` 证书签名的 bundle；如设置 `EXPECTED_TEAM_ID` 或 `EXPECTED_SIGNING_CERT_SHA256`，会在提交 notarization 前再次校验证书身份；通过后会提交 zip、等待 notarization、staple ticket、运行 `stapler validate` 和 `spctl --assess`。

### Developer ID 分发

1. 设置 `SIGN_IDENTITY="Developer ID Application: ..."` 后运行 `./scripts/package_release.sh`，构建 Developer ID 签名并启用 Hardened Runtime 的 `.app`。建议同时设置 `EXPECTED_TEAM_ID` 和 `EXPECTED_SIGNING_CERT_SHA256`，避免误用错误证书。
2. 验证签名：

   ```bash
   codesign --verify --deep --strict --verbose=2 PasswordManager.app
   ```

3. 使用脚本生成的 zip，或重新创建用于 notarization 的 zip：

   ```bash
   ditto -c -k --sequesterRsrc --keepParent PasswordManager.app PasswordManager.zip
   ```

4. 提交 notarization，可以使用脚本：

   ```bash
   NOTARY_KEYCHAIN_PROFILE=password-manager-notary \
   ./scripts/notarize_release.sh
   ```

   或手动提交：

   ```bash
   xcrun notarytool submit PasswordManager.zip \
     --apple-id "$APPLE_ID" \
     --team-id "$TEAM_ID" \
     --password "$APP_SPECIFIC_PASSWORD" \
     --wait
   ```

5. Staple 并验证：

   ```bash
   xcrun stapler staple PasswordManager.app
   spctl --assess --type execute --verbose=2 PasswordManager.app
   ```

### Mac App Store 上架

1. 使用 App Store bundle identifier、Apple Distribution signing 和 App Store provisioning profile。
2. 启用 App Sandbox，仅保留文件访问、网络同步和 Keychain 所需 entitlement；当前 `ReleaseSupport/PasswordManagerMacOS.entitlements` 可作为最小起点。
3. 使用 Xcode archive 或等价 CI archive，确保 bundle metadata、版本号、`AppIcon.icns` 和 `PrivacyInfo.xcprivacy` 完整。
4. Validate archive。
5. 通过 Xcode Organizer 或 Transporter 上传。
6. 在 App Store Connect 中补全隐私营养标签、加密出口合规、截图、支持 URL、营销 URL、年龄分级和 review notes。
7. 提交审核。

### 发布检查清单

- [x] 原生存储使用本地 vault envelope，通过 AES-256-GCM 加密。
- [x] 主密钥 verifier 使用现有默认迭代次数的 PBKDF2-SHA256。
- [x] 单元测试覆盖 PBKDF2 verifier 行为、AES-GCM 往返、篡改拒绝，以及加密保险库文件无明文泄露。
- [x] TOTP 解锁验证与 Flutter auth package 默认参数一致：SHA1、30 秒周期、6 位数字、+/-1 时间窗口。
- [x] 手动备份会创建带时间戳的本地加密保险库 envelope 副本。
- [x] 本地备份支持恢复最新加密备份，并保留最近 5 个备份。
- [x] 完整快照 JSON 导入/导出可通过 macOS 系统文件选择器/导出器使用，并保留本地 app support 目录兼容流程。
- [x] 分类/标签管理支持创建、重命名、删除，并与 Android 端删除分类/删除标签的条目更新行为一致。
- [x] 创建菜单支持新建条目、创建分类和创建标签。
- [x] 条目编辑器支持分类选择、标签多选，以及编辑时创建分类/标签。
- [x] 详情页支持字段复制，敏感字段支持显示/隐藏和复制。
- [x] 清空数据入口要求主密码确认，并与 Android 端一致地清空条目、分类、标签和保险库安全设置。
- [x] 跨实现 fixture 测试证明 Swift 可以派生并解密当前 Dart crypto package 生成的多条目 payload。
- [x] 兼容性 fixture 覆盖 credential、server、service、service accounts、metadata、version vectors、`updatedBy` 和 tombstones；macOS 删除条目会写入 `deletedAt`，编辑恢复会清为 `nil`。
- [x] 同步合并数据层覆盖 version-vector 支配、并发冲突、delete-vs-update tombstone 和 keep-both conflict copy。
- [x] WebDAV 和 S3 presigned URL 同步 transport 层覆盖路径归一化、Basic Auth、JSON PUT 和网络错误映射。
- [x] 同步设置模型和 provider client factory 覆盖 Flutter 字段契约、默认值和未知值兼容。
- [x] 同步引擎数据层覆盖缺失远端、远端支配、并发冲突合并上传和 revision/status/log 更新。
- [x] Keychain-backed sync secret store 已实现；同步敏感字段可从普通设置中 redacted 后保存。
- [x] 同步设置 UI 已接入 Keychain secret store，且普通配置文件不持久化明文同步 secrets。
- [x] 手动同步入口已连接 provider client factory、同步引擎、加密保险库持久化和同步设置持久化。
- [x] 本地 `.app` 打包脚本、可重复生成的 `.icns` app icon、Developer ID notarization/staple 脚本、Info.plist 模板、privacy manifest 和最小 entitlements 已提供。
- [x] 本地 package smoke 脚本会串联 `swift test`、打包、bundle metadata/resource/codesign/zip 检查和 release `.app` 启动冒烟。
- [x] ad-hoc + Hardened Runtime 本地包已通过 codesign 验证、zip 解压验证和本机启动冒烟验证。
- [x] 打包脚本在 Developer ID identity 下启用 secure timestamp，并提供可执行 notarization/staple/re-assess 发布门禁脚本。
- [x] 打包和 notarization 脚本支持 `EXPECTED_TEAM_ID` 与 `EXPECTED_SIGNING_CERT_SHA256`，可在发布前校验 Developer ID 签名身份。
- [x] 打包脚本会将 `PrivacyInfo.xcprivacy` 放入 bundle resources，并随 app 签名封装。
- [x] 打包脚本会生成 `AppIcon.icns`、设置 `CFBundleIconFile=AppIcon`，并随 app 签名封装。
- [ ] 真实 WebDAV/S3 端到端服务验证完成。
- [ ] 增加 sync conflict、import/export 和 backup flow 的更完整兼容性 fixtures。
- [x] App Sandbox、network client、user-selected file access 和默认 Keychain 使用方式已审查并写入发布说明。
- [ ] Developer ID 或 Mac App Store 签名、notarization/上传和干净 macOS 账户安装测试完成。

---

## English

This directory contains the native macOS application target, used to build macOS-native parity incrementally.

### Scope

- SwiftUI macOS app built with the macOS 26 SDK using `WindowGroup`, native sidebar/list/detail layout, menu commands, and a Settings scene; search and toolbar structure use the macOS 26 / Liquid Glass-era system `NavigationSplitView`, `searchToolbarBehavior`, and `ToolbarSpacer` APIs.
- First native parity slice: initialize/unlock vault, lock vault, list entries, search/filter, detail field copy and secret reveal, add/edit/delete credential/server/service entries, category and tag fields, category/tag management, clear vault data, TOTP-based 2FA unlock verification, manual sync entry point, local encrypted backup creation, and full snapshot JSON import/export.
- Data model mirrors the current shared contract: `credential`, `server`, `service`, PBKDF metadata records, AES-GCM payload record shape, soft-delete fields, deletion tombstone timestamps, version map, and `updatedBy`.
- The entry-reference data contract is preserved by Codable models, encrypted snapshots, sync, and item/category import/export. A pure resolver now returns `empty`, `resolved`, `missing`, `deleted`, or `categoryMismatch` with a safe target projection. Tags remain unchanged. Reference editing UI, search integration, lifecycle propagation, and import remapping are not exposed yet; see `../../docs/FIELD_REFERENCE_CONTRACT.md` for the format and rollout order.
- Local encrypted file persistence is implemented. The app writes an encrypted vault envelope to Application Support using PBKDF2-SHA256 master password verification and AES-256-GCM payload encryption.
- PBKDF2 defaults are aligned with the Dart package contract: 600000 iterations for new native macOS vaults.
- Unit coverage exists for PBKDF2 verifier determinism, AES-GCM round trip, tamper rejection, TOTP generation/verification, encrypted envelope persistence without plaintext secret leakage, latest encrypted backup restore, backup retention, sync merge data layer, and decrypting a multi-entry fixture generated by `packages/crypto`.
- Local backup supports restoring the latest encrypted backup and automatically keeps the latest 5 backup files.
- Sync merge data layer matches the Flutter version-vector rules: local/remote dominance, concurrent conflicts, delete-vs-update tombstones, and keep-both conflict copies are covered by Swift tests.
- Remote sync transport now matches the Flutter WebDAV and S3 presigned URL clients: path normalization, Basic Auth, JSON PUT, 404/204 empty remote handling, and timeout/error status mapping are covered by Swift tests.
- Sync settings now mirror the Flutter field contract: provider type, WebDAV/NAS WebDAV, S3 presigned URL, auto-sync, conflict strategy, sync master key, device id, revision, status, and logs. A native client factory can select WebDAV, NAS WebDAV, or S3 presigned URL clients from those settings.
- Saving sync settings adopts the repository-normalized device id so in-memory state, the plaintext settings file, and Keychain secret ownership stay aligned with Android store behavior.
- Sync engine data layer now downloads remote payloads, merges local/remote snapshots, applies remote-dominant results, uploads new revisions, and updates sync revision/status/logs. Missing remote, remote-dominant, and concurrent-conflict upload scenarios are covered.
- A Keychain-backed sync secret store has been added. `webdavPassword` and presigned download/upload URLs can be redacted from normal `SyncSettings` before plaintext storage; tests cover redaction/apply-secrets, the secret-store lifecycle, no plaintext secrets in normal config files, and `VaultStore` sync settings reload.
- Sync settings UI is wired through `VaultStore` and the Keychain secret store. The manual sync entry point now connects `SyncClientFactory` with `VaultSyncEngine`, uploads local payloads, applies merge results, and persists revision/status/logs.
- A local `.app` packaging script, reproducible `.icns` app icon generation, Developer ID notarization/staple script, Info.plist template, privacy manifest, and minimal entitlements are now included. By default it creates an ad-hoc signed Hardened Runtime bundle for local validation; Developer ID / Mac App Store release still requires a real signing identity plus notarization or upload validation.
- Real WebDAV/S3 end-to-end service validation and pre-release security review must still be completed before production release.

### Requirements

- macOS 26 or later.
- Xcode with SwiftPM 6.2, Swift 6.3 or newer toolchain, and the macOS 26 SDK.

Check the local toolchain:

```bash
swift --version
```

### Develop

From this directory:

```bash
swift run PasswordManagerMacOS
```

The encrypted vault file is stored at:

```text
~/Library/Application Support/PasswordManagerNative/vault.json
```

Manual backups copy the encrypted vault envelope to:

```text
~/Library/Application Support/PasswordManagerNative/backups/
```

Snapshot JSON exports now use the macOS system file exporter by default and can be saved to a user-selected location. The legacy local export flow still writes to:

```text
~/Library/Application Support/PasswordManagerNative/exports/
```

Snapshot JSON imports now use the macOS system file picker by default and can read a user-selected `.json` file. The legacy local import flow still reads from:

```text
~/Library/Application Support/PasswordManagerNative/imports/
```

Build only:

```bash
swift build
```

Run tests:

```bash
swift test
```

### Local Encryption Verification

Use this flow after changing persistence or crypto code:

1. Run the app:

   ```bash
   swift run PasswordManagerMacOS
   ```

2. Initialize the vault with a master password.
3. Add at least one credential, one server, and one service entry.
4. Quit and reopen the app.
5. Verify the wrong password fails and the correct password restores all entries.
6. In Settings, save a Base32 TOTP shared secret, enable 2FA, lock the vault, and verify unlock rejects missing/invalid codes and accepts a current authenticator code.
7. Run manual backup and verify `backups/vault-*.json` is created and contains the encrypted envelope, not plaintext vault fields.
8. Run JSON export and verify the `vault-export-*.json` saved by the system file exporter contains the expected full snapshot JSON.
9. Select a snapshot JSON file through the system file picker, run JSON import, and verify entries/categories/tags/security settings are replaced by the imported snapshot; the legacy `imports/` directory flow remains available for local verification.
10. Inspect `~/Library/Application Support/PasswordManagerNative/vault.json` and confirm plaintext labels, usernames, passwords, tokens, server names, and service names are not present in the file.
11. Run `swift test` and `swift build` before committing.

The automated test suite currently verifies:

- PBKDF2-SHA256 verifier determinism for fixed salt and iterations.
- Correct password verification and wrong password rejection.
- AES-GCM encryption/decryption round trip with deterministic nonce input.
- AES-GCM tamper rejection when the authentication tag changes.
- TOTP SHA1 code generation and verification with the same 30-second period, 6-digit length, and +/-1 window used by the Flutter auth package.
- Manual backup copies the encrypted vault envelope to a timestamped local backup file.
- Local backup restores the latest encrypted backup and automatically keeps the latest 5 backup files.
- Full snapshot JSON export/import round trips through the system file exporter/picker, with the local `exports/` and `imports/` directory compatibility flow retained.
- Full snapshot JSON decoding accepts both Android's `backupStatus` key and the earlier Swift `lastBackupStatus` key.
- Category/tag management covers create, duplicate rejection, rename, and delete; deleting a category uncategorizes existing entries, and deleting a tag removes it from existing entries.
- The sidebar toolbar create entry now matches the Android create menu, with actions for adding an entry, creating a category, and creating a tag.
- The entry editor now matches the Android category/tag workflow: search and choose existing categories, search and multi-select existing tags, and create a category or tag while editing an entry.
- Detail fields support one-click copy; passwords and secrets are hidden by default and can be revealed/hidden and copied.
- Entry deletion now records a deletion tombstone timestamp and clears that timestamp if an existing entry is restored through editing, matching Android store behavior.
- Clear data requires master password confirmation and clears entries, categories, tags, 2FA settings, and local backup status; the Touch ID unlock credential is cleared at the same time.
- Encrypted vault envelope persistence without plaintext labels, usernames, passwords, access keys, or secret keys in `vault.json`.
- Cross-implementation compatibility with a fixture generated by the current Dart `packages/crypto` implementation.
- The Dart fixture covers credential, server, service, service accounts, category/tag metadata, security settings, sync status, version vectors, `updatedBy`, and a soft-delete tombstone.
- Snapshot JSON decoding accepts both Android `backupStatus` and Swift `lastBackupStatus` fields so full snapshots remain importable across native clients.
- WebDAV / S3 presigned URL sync transport matches Flutter URL construction, auth headers, upload/download HTTP methods, and network error status mapping.
- Sync settings defaults, tolerant decoding, Flutter field-name encoding, and provider client factory validation.
- Sync settings saves adopt the repository-normalized device id, so an empty device id is generated and immediately written back to `VaultStore`.
- Sync engine coverage for uploading local payloads when the remote is missing, applying remote-dominant payloads without upload, and merging concurrent conflicts into the next uploaded revision.
- Sync sensitive-field redaction, Keychain secret-store boundary, no plaintext sync secrets in normal config files, in-memory secret-store lifecycle, and `VaultStore` sync settings persistence.
- `VaultStore.syncNow(client:)` uploads the local snapshot through the sync engine, updates revision/status/logs, and writes the result back to the encrypted vault.

Regenerate the Dart crypto fixture after intentional Dart crypto contract changes:

```bash
cd ../../
dart pub get --directory packages/crypto
dart --packages=packages/crypto/.dart_tool/package_config.json \
  apps/macos_native/Tests/PasswordManagerMacOSTests/Fixtures/generate_dart_crypto_fixture.dart \
  > apps/macos_native/Tests/PasswordManagerMacOSTests/Fixtures/dart_crypto_fixture.json
cd apps/macos_native
swift test
```

### Release Build

SwiftPM can produce a release executable:

```bash
swift build -c release
```

This directory also includes a local `.app` packaging script:

```bash
./scripts/package_release.sh
```

The packaging script defaults to `0.1.0 (1)`: the marketing version is written to
`CFBundleShortVersionString`, and the build number is written to `CFBundleVersion`.
Both values must be one to three dot-separated integer segments, such as `1`,
`1.0`, or `1.0.0`. Set them with any of these forms:

```bash
./scripts/package_release.sh 1.0.0 100
./scripts/package_release.sh --version 1.0.0 --build-number 100
MARKETING_VERSION=1.0.0 BUILD_NUMBER=100 ./scripts/package_release.sh
```

The script copies `ReleaseSupport/Info.plist` as the template, then writes the
actual app name, bundle id, icon name, marketing version, and build number into
the packaged app. The bundle metadata in the release artifact therefore comes
from the packaging arguments for that run.

Run the local release-candidate smoke gate with:

```bash
./scripts/package_smoke.sh
```

The script runs `swift test`, packages the local `.app`, checks bundle metadata, `PrivacyInfo.xcprivacy`, `AppIcon.icns`, entitlements, codesign, extracted-zip signature/resources, and launches the packaged `.app` for a local smoke test. Gatekeeper rejection remains expected for the default ad-hoc package because it is not notarized; Developer ID distribution still requires the notarization flow.

Default output:

```text
dist/release/Password Manager.app
dist/release/Password Manager.zip
```

The script:

1. Runs `swift build -c release`.
2. Assembles an `.app` bundle.
3. Writes bundle metadata from `ReleaseSupport/Info.plist`.
4. Copies `ReleaseSupport/PrivacyInfo.xcprivacy` into bundle resources.
5. Generates an iconset with `scripts/generate_app_icon.swift` and converts it to `AppIcon.icns` with `iconutil`.
6. Signs with `ReleaseSupport/PasswordManagerMacOS.entitlements`.
7. Uses ad-hoc identity `-` plus Hardened Runtime by default for local validation; when a Developer ID identity is provided, secure timestamping is enabled for notarization readiness.
8. Runs `codesign --verify --deep --strict`.
9. Verifies the signing TeamIdentifier and leaf signing certificate SHA-256 fingerprint when `EXPECTED_TEAM_ID` or `EXPECTED_SIGNING_CERT_SHA256` is set.
10. Creates a zip with the structure expected by notarization.

More release metadata and signing identity can be overridden with environment variables:

```bash
APP_NAME="Password Manager" \
BUNDLE_ID=life.devops.passwordmanager \
MARKETING_VERSION=1.0.0 \
BUILD_NUMBER=100 \
ICON_NAME=AppIcon \
SIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
./scripts/package_release.sh
```

By default, `SIGN_IDENTITY=-` creates an ad-hoc signed package without an
entitlements file and disables secure timestamping; this is only for local
validation. When a `Developer ID Application: ...` identity is provided, the
script uses `ReleaseSupport/PasswordManagerMacOS.entitlements`, enables Hardened
Runtime, and requests secure timestamping so the artifact meets the signing
prerequisites for notarization. Use `ENTITLEMENTS=/path/to/file.plist` to point
the package at a different entitlements file.

For Developer ID releases, pin the signing certificate to the expected Team ID and certificate fingerprint:

```bash
SIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
EXPECTED_TEAM_ID=TEAMID \
EXPECTED_SIGNING_CERT_SHA256=AA:BB:CC:... \
./scripts/package_release.sh
```

The current privacy manifest declares no tracking, no tracking domains, no collected data types, and no required-reason API usage. If telemetry, third-party SDKs, accounts, pasteboard, disk-space, file-timestamp, or other required-reason API usage is added later, update `ReleaseSupport/PrivacyInfo.xcprivacy` and the App Store Connect privacy answers at the same time.

The app icon is currently generated by `scripts/generate_app_icon.swift` during packaging. The script writes `dist/release/AppIcon.iconset`, converts it to `Contents/Resources/AppIcon.icns`, and `ReleaseSupport/Info.plist` declares `CFBundleIconFile=AppIcon`. Once final brand artwork exists, replace the generator or commit a design-provided `.icns`, but keep `CFBundleIconFile` aligned with the bundled resource.

Current entitlements are minimized to App Sandbox, outgoing network client, and user-selected read-only/read-write file access. Sync secrets use the default Keychain generic password item, which does not need a separate Keychain access group; add Keychain Sharing only if a shared group is introduced later.

Developer ID notarization can be run with the included script:

```bash
NOTARY_KEYCHAIN_PROFILE=password-manager-notary \
./scripts/notarize_release.sh
```

Or by passing Apple ID credentials directly:

```bash
APPLE_ID=developer@example.com \
TEAM_ID=ABCDE12345 \
APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx \
./scripts/notarize_release.sh
```

The script rejects ad-hoc signed apps and requires a bundle signed by a `Developer ID Application:` certificate. When `EXPECTED_TEAM_ID` or `EXPECTED_SIGNING_CERT_SHA256` is set, it re-validates the signing identity before notarization submission. On success it submits the zip, waits for notarization, staples the ticket, runs `stapler validate`, and re-runs `spctl --assess`.

### Developer ID Distribution

1. Set `SIGN_IDENTITY="Developer ID Application: ..."` and run `./scripts/package_release.sh` to build a Developer ID signed `.app` with Hardened Runtime enabled. Also set `EXPECTED_TEAM_ID` and `EXPECTED_SIGNING_CERT_SHA256` to avoid signing with the wrong certificate.
2. Verify the signature:

   ```bash
   codesign --verify --deep --strict --verbose=2 PasswordManager.app
   ```

3. Use the script-generated zip, or recreate a zip for notarization:

   ```bash
   ditto -c -k --sequesterRsrc --keepParent PasswordManager.app PasswordManager.zip
   ```

4. Submit for notarization with the script:

   ```bash
   NOTARY_KEYCHAIN_PROFILE=password-manager-notary \
   ./scripts/notarize_release.sh
   ```

   Or submit manually:

   ```bash
   xcrun notarytool submit PasswordManager.zip \
     --apple-id "$APPLE_ID" \
     --team-id "$TEAM_ID" \
     --password "$APP_SPECIFIC_PASSWORD" \
     --wait
   ```

5. Staple and verify:

   ```bash
   xcrun stapler staple PasswordManager.app
   spctl --assess --type execute --verbose=2 PasswordManager.app
   ```

### Mac App Store Submission

1. Use an App Store bundle identifier, Apple Distribution signing, and an App Store provisioning profile.
2. Enable App Sandbox and only the entitlements required for file access, network sync, and Keychain; `ReleaseSupport/PasswordManagerMacOS.entitlements` is the current minimal starting point.
3. Archive with Xcode or an equivalent CI archive flow, and confirm bundle metadata, version, `AppIcon.icns`, and `PrivacyInfo.xcprivacy` are complete.
4. Validate the archive.
5. Upload through Xcode Organizer or Transporter.
6. In App Store Connect, complete privacy nutrition labels, encryption export compliance, screenshots, support URL, marketing URL, age rating, and review notes.
7. Submit for review.

### Release Checklist

- [x] Native storage is encrypted with AES-256-GCM in a local vault envelope.
- [x] Master key verifier uses PBKDF2-SHA256 with the existing default iteration count.
- [x] Unit tests cover PBKDF2 verifier behavior, AES-GCM round trip, tamper rejection, and no plaintext leakage in the encrypted vault file.
- [x] TOTP unlock verification matches the Flutter auth package defaults: SHA1, 30-second period, 6 digits, and +/-1 time window.
- [x] Manual backup creates a timestamped local copy of the encrypted vault envelope.
- [x] Local backup restores the latest encrypted backup and keeps the latest 5 backups.
- [x] Full snapshot JSON export/import is available through the macOS system file picker/exporter, with the local app support directory compatibility flow retained.
- [x] Category/tag management supports create, rename, and delete, matching Android entry updates when categories or tags are deleted.
- [x] The create menu supports adding entries, creating categories, and creating tags.
- [x] The entry editor supports searchable category selection, searchable tag multi-select, and creating categories/tags while editing.
- [x] Detail fields support copy actions, and sensitive fields support reveal/hide plus copy.
- [x] Clear data requires master password confirmation and clears entries, categories, tags, and vault security settings in line with Android behavior.
- [x] Cross-implementation fixture test proves Swift can derive and decrypt a multi-entry payload generated by the current Dart crypto package.
- [x] Compatibility fixture covers credential, server, service, service accounts, metadata, version vectors, `updatedBy`, and tombstones; macOS entry deletion records `deletedAt` and editing restores it to `nil`.
- [x] Sync merge data layer covers version-vector dominance, concurrent conflicts, delete-vs-update tombstones, and keep-both conflict copies.
- [x] WebDAV and S3 presigned URL sync transport covers path normalization, Basic Auth, JSON PUT, and network error mapping.
- [x] Sync settings model and provider client factory cover the Flutter field contract, defaults, and unknown-value tolerance.
- [x] Sync engine data layer covers missing remote, remote dominance, concurrent conflict merge/upload, and revision/status/log updates.
- [x] Keychain-backed sync secret store is implemented; sync-sensitive fields can be redacted from normal settings before saving.
- [x] Sync settings UI uses the Keychain secret store and normal config files do not persist plaintext sync secrets.
- [x] Manual sync entry point is connected to the provider client factory, sync engine, encrypted vault persistence, and sync settings persistence.
- [x] Local `.app` packaging script, reproducible `.icns` app icon generation, Developer ID notarization/staple script, Info.plist template, privacy manifest, and minimal entitlements are included.
- [x] Local package smoke script gates `swift test`, packaging, bundle metadata/resource/codesign/zip checks, and release `.app` launch smoke.
- [x] The ad-hoc + Hardened Runtime local package passes codesign verification, zip extraction verification, and local launch smoke validation.
- [x] The packaging script enables secure timestamping for Developer ID identities and includes an executable notarization/staple/re-assess release gate.
- [x] Packaging and notarization scripts support `EXPECTED_TEAM_ID` and `EXPECTED_SIGNING_CERT_SHA256` gates for Developer ID signing identity verification.
- [x] The packaging script places `PrivacyInfo.xcprivacy` in bundle resources so it is sealed into the signed app.
- [x] The packaging script generates `AppIcon.icns`, sets `CFBundleIconFile=AppIcon`, and seals the icon into the signed app.
- [ ] Real WebDAV/S3 end-to-end service validation is complete.
- [ ] Add broader compatibility fixtures for sync conflicts, import/export, and backup flows.
- [x] App Sandbox, network client, user-selected file access, and default Keychain usage are reviewed and documented for release.
- [ ] Developer ID or Mac App Store signing, notarization/upload, and clean macOS account install testing are complete.
