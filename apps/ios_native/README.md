# Password Manager iOS Native

## 中文

该目录包含 iOS 原生应用，用于逐步补齐 iOS 端原生能力。

### 范围

- 使用 Swift 和 SwiftUI 建立 iOS 原生起点。
- 当前切片复用并迁移 macOS 原生端已验证的 Swift 核心：数据模型、本地加密持久化、TOTP、导入导出、备份、同步设置、远端同步 transport、同步合并和同步引擎。
- SwiftUI 视图已放入 `PasswordManageriOSCore`，并提供 `PasswordManageriOSAppRoot` 作为 Xcode iOS app target 的根视图。
- 当前包含 SwiftPM 可测试核心模块和 `PasswordManageriOS.xcodeproj` 原生 app target。
- 已配置 Debug/Release build configuration、bundle identifier、生成式 launch screen、asset catalog、空 entitlements、包含 UserDefaults required-reason 声明的 privacy manifest，以及本机可运行的 Release simulator build/install/launch smoke + generic iOS archive contract gate。生产发布前仍需配置 Apple Developer Team/signing、真机验证和 App Store Connect 验证。
- 本目录不依赖已移除的 Flutter iOS 工程。

### 目录说明

- `Package.swift`: SwiftPM 包定义。
- `PasswordManageriOS.xcodeproj`: iOS app target 工程。
- `PasswordManageriOS`: iOS app 入口、asset catalog、entitlements 和 privacy manifest。
- `Sources/PasswordManageriOSCore/App`: iOS app root wiring。
- `Sources/PasswordManageriOSCore/Models`: vault 数据模型。
- `Sources/PasswordManageriOSCore/Services`: crypto 与 TOTP 服务。
- `Sources/PasswordManageriOSCore/Stores`: encrypted vault repository 与 app state store。
- `Sources/PasswordManageriOSCore/Sync`: sync settings、secret store、remote clients、merge 和 engine。
- `Sources/PasswordManageriOSCore/Views`: SwiftUI vault UI 起点。
- `Tests/PasswordManageriOSCoreTests`: core 兼容性和行为测试。

### 环境要求

- macOS 14 或更高版本。
- Xcode，含 Swift 6 toolchain。
- 后续真机/App Store 验证需要 Apple Developer Program 账号、iOS provisioning profile 和 App Store Connect 访问权限。

检查工具链：

```bash
swift --version
xcodebuild -version
```

### 开发

核心模块可通过 SwiftPM 构建和测试：

```bash
swift build
swift test
```

Xcode app target 可通过 Xcode 或命令行构建。常规 simulator 编译：

```bash
xcodebuild build \
  -project PasswordManageriOS.xcodeproj \
  -target PasswordManageriOS \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO
```

本地 simulator 安装和启动示例：

```bash
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted build/Debug-iphonesimulator/PasswordManageriOS.app
xcrun simctl launch booted life.devops.passwordmanager
```

运行本地 release gate：

```bash
./scripts/verify_release.sh
```

该脚本会运行 SwiftPM 测试、Release simulator build、simulator 安装/启动 smoke，并创建 `build/PasswordManageriOS.xcarchive` 的 generic iOS archive；默认使用 `CODE_SIGNING_ALLOWED=NO` 做本机 archive 内容校验，不声称已完成 Apple 签名。配置 Apple Developer Team 后，可强制签名 archive：

```bash
IOS_REQUIRE_SIGNED_ARCHIVE=true \
IOS_DEVELOPMENT_TEAM=ABCDE12345 \
IOS_CODE_SIGN_IDENTITY="Apple Distribution" \
IOS_ALLOW_PROVISIONING_UPDATES=true \
./scripts/verify_release.sh
```

simulator smoke 默认创建临时 iPhone simulator，安装 `build/Release-iphonesimulator/PasswordManageriOS.app`，通过 `simctl appinfo` 确认安装，再启动 `life.devops.passwordmanager`，并保存启动截图到 `build/simulator-smoke/launch.png`。如需复用指定模拟器，可设置 `IOS_SIMULATOR_UDID=<udid>`。

### 本地功能验证

当前可自动验证的范围：

- PBKDF2-SHA256 verifier 与默认迭代次数。
- AES-256-GCM 加密/解密和 tamper rejection。
- 加密 vault envelope 不在 `vault.json` 泄露明文密码库字段。
- TOTP SHA1、30 秒周期、6 位数字、+/-1 窗口。
- 完整快照 JSON 导入/导出。
- 单条/分类 scoped JSON 导入/导出和冲突策略。
- 本地加密备份、恢复最新备份、保留最近 5 个备份。
- Dart crypto fixture 解密兼容。
- WebDAV / S3 presigned URL remote sync transport 行为。
- 同步设置 redaction、secret store 生命周期和普通配置文件无明文 sync secrets。
- 同步合并和 `VaultStore.syncNow(client:)` 写回流程。

已在 iPhone 17 Pro simulator 启动验证初始 `Initialize Vault` 界面。真机和发布候选环境仍需手动验证：

1. 初始化密码库。
2. 新增 credential、server、service 条目。
3. 搜索、分类、标签筛选。
4. 锁定、解锁和 TOTP 解锁。
5. 杀进程重启后数据保留。
6. 导入、导出、备份、恢复。
7. WebDAV 或 S3 presigned URL 真实服务同步。
8. iPhone portrait/landscape、iPad split view、Dynamic Type、深色模式和 VoiceOver 基础可访问性。

### 发布构建

当前已创建 Xcode iOS app target，并且本地 release gate 会生成 generic iOS archive 并校验 bundle id、版本号、arm64 app、privacy manifest、Assets.car 和 dSYM。发布 iOS app 前还需要完成 Apple signing、真机安装和 App Store Connect 验证：

1. 在 `PasswordManageriOS.xcodeproj` 中设置 Apple Developer Team、release signing certificate 和 provisioning profile。
2. 确认正式 1024x1024 app icon 和 asset catalog 参与 Release target。
3. 更新 display name、version、build number、deployment target 和 App Store Connect bundle id。
4. 按实际实现最小化配置必要 entitlements；当前通用 Keychain password item 不需要额外 keychain access group。
5. 审查 `PrivacyInfo.xcprivacy`；当前已声明 `@AppStorage`/UserDefaults 的 `CA92.1` required reason，新增 required-reason API 或数据收集时必须同步更新。
6. 选择 Generic iOS Device 或 Any iOS Device。
7. 执行 Product > Archive。
8. Validate archive。
9. 上传到 App Store Connect 或导出 Ad Hoc / Development 包做 QA。

命令行归档示例在 Xcode project 建立后使用：

```bash
xcodebuild archive \
  -project PasswordManageriOS.xcodeproj \
  -scheme PasswordManageriOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/PasswordManageriOS.xcarchive
```

本地无签名 archive contract 可由 release gate 自动执行；上传候选包必须设置 `IOS_REQUIRE_SIGNED_ARCHIVE=true`，并在 Apple signing 通过后再进入 Validate archive / TestFlight。

### TestFlight / App Store 上架

1. 在 Apple Developer 账号中创建 App ID，并启用所需 capabilities。
2. 在 App Store Connect 创建 app record，填写 bundle id、SKU、默认语言和分类。
3. 配置 signing certificates、provisioning profiles 或使用 Xcode automatic signing。
4. Archive 并上传 build。
5. 在 App Store Connect 中等待处理完成。
6. 配置 TestFlight 内部测试，完成安装、初始化、解锁、导入导出、备份、同步和重启验证。
7. 准备隐私信息：数据收集、加密说明、账号/密码库数据处理、网络同步说明、隐私政策 URL。
8. 准备截图、描述、关键词、支持 URL、营销 URL、年龄分级、App Review notes 和演示账号/步骤。
9. 提交 App Review。
10. 审核通过后选择手动发布或自动发布。

官方入口：

- App Store Connect Help：https://developer.apple.com/help/app-store-connect/
- TestFlight：https://developer.apple.com/testflight/
- Distributing apps in Xcode：https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases

### 发布检查清单

- [x] iOS 原生目录在 `apps/ios_native` 下创建。
- [x] SwiftPM core 模块可构建。
- [x] README 提供中文和英文版本。
- [x] README 说明开发、发布构建、TestFlight 和 App Store 上架步骤。
- [x] Core 测试覆盖 macOS 原生端已验证的 crypto、TOTP、导入导出、备份和同步数据层。
- [x] Xcode iOS app target 已创建。
- [x] iOS bundle id、生成式 launch screen、空 entitlements、app icon asset 和 UserDefaults privacy manifest 已配置。
- [x] iOS simulator build/run 已验证。
- [x] 本地 release gate 可在 iOS simulator 中安装并启动 Release app，确认 bundle id、安装状态和启动截图。
- [x] 本地 release gate 会生成 generic iOS archive，并校验 arm64 app、Info.plist、privacy manifest、Assets.car 和 dSYM。
- [ ] Apple Developer Team、release signing、真机安装和 App Store/TestFlight 上传验证已完成。
- [ ] iOS 真机安装和基础回归已验证。
- [ ] 真实 WebDAV/S3 同步服务端到端验证完成。
- [ ] TestFlight internal testing 安装验证完成。
- [ ] App Store Review 通过。

---

## English

This directory contains the native iOS application target, used to build iOS-native parity incrementally.

### Scope

- Native iOS starting point written in Swift and SwiftUI.
- The current slice migrates the already-verified Swift core from the native macOS target: data models, local encrypted persistence, TOTP, import/export, backup, sync settings, remote sync transport, sync merge, and sync engine.
- SwiftUI views are included in `PasswordManageriOSCore`, and `PasswordManageriOSAppRoot` is used as the root view for the Xcode iOS app target.
- The current form includes a SwiftPM-tested core module and a `PasswordManageriOS.xcodeproj` native app target.
- Debug/Release build configurations, bundle identifier, generated launch screen, asset catalog, empty entitlements, a privacy manifest with the UserDefaults required-reason disclosure, and a locally runnable Release simulator build/install/launch smoke + generic iOS archive contract gate are configured. Production release still needs Apple Developer Team/signing, device validation, and App Store Connect validation.
- This directory does not depend on the removed Flutter iOS project.

### Directory Layout

- `Package.swift`: SwiftPM package definition.
- `PasswordManageriOS.xcodeproj`: iOS app target project.
- `PasswordManageriOS`: iOS app entry point, asset catalog, entitlements, and privacy manifest.
- `Sources/PasswordManageriOSCore/App`: iOS app root wiring.
- `Sources/PasswordManageriOSCore/Models`: vault data models.
- `Sources/PasswordManageriOSCore/Services`: crypto and TOTP services.
- `Sources/PasswordManageriOSCore/Stores`: encrypted vault repository and app state store.
- `Sources/PasswordManageriOSCore/Sync`: sync settings, secret store, remote clients, merge, and engine.
- `Sources/PasswordManageriOSCore/Views`: SwiftUI vault UI starting point.
- `Tests/PasswordManageriOSCoreTests`: core compatibility and behavior tests.

### Requirements

- macOS 14 or later.
- Xcode with the Swift 6 toolchain.
- Device/App Store validation later requires an Apple Developer Program account, iOS provisioning profiles, and App Store Connect access.

Check the toolchain:

```bash
swift --version
xcodebuild -version
```

### Develop

The core module builds and tests with SwiftPM:

```bash
swift build
swift test
```

The Xcode app target can be built from Xcode or the command line. Standard simulator build:

```bash
xcodebuild build \
  -project PasswordManageriOS.xcodeproj \
  -target PasswordManageriOS \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO
```

Local simulator install and launch example:

```bash
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted build/Debug-iphonesimulator/PasswordManageriOS.app
xcrun simctl launch booted life.devops.passwordmanager
```

Run the local release gate:

```bash
./scripts/verify_release.sh
```

The script runs SwiftPM tests, a Release simulator build, simulator install/launch smoke, and creates `build/PasswordManageriOS.xcarchive` as a generic iOS archive. By default it uses `CODE_SIGNING_ALLOWED=NO` for local archive content validation and does not claim Apple signing is complete. After configuring an Apple Developer Team, require a signed archive with:

```bash
IOS_REQUIRE_SIGNED_ARCHIVE=true \
IOS_DEVELOPMENT_TEAM=ABCDE12345 \
IOS_CODE_SIGN_IDENTITY="Apple Distribution" \
IOS_ALLOW_PROVISIONING_UPDATES=true \
./scripts/verify_release.sh
```

The simulator smoke creates a temporary iPhone simulator by default, installs `build/Release-iphonesimulator/PasswordManageriOS.app`, verifies the installation with `simctl appinfo`, launches `life.devops.passwordmanager`, and writes a launch screenshot to `build/simulator-smoke/launch.png`. Set `IOS_SIMULATOR_UDID=<udid>` to reuse a specific simulator.

### Local Feature Verification

The current automated scope covers:

- PBKDF2-SHA256 verifier and default iteration count.
- AES-256-GCM encryption/decryption and tamper rejection.
- Encrypted vault envelope without plaintext vault fields in `vault.json`.
- TOTP SHA1, 30-second period, 6 digits, and +/-1 time window.
- Full snapshot JSON import/export.
- Item/category scoped JSON import/export and conflict strategies.
- Local encrypted backup, latest-backup restore, and latest-5 retention.
- Dart crypto fixture decryption compatibility.
- WebDAV / S3 presigned URL remote sync transport behavior.
- Sync settings redaction, secret-store lifecycle, and no plaintext sync secrets in normal config files.
- Sync merge and `VaultStore.syncNow(client:)` writeback flow.

The initial `Initialize Vault` screen has been launched on an iPhone 17 Pro simulator. Device and release-candidate environments still need manual verification:

1. Initialize the vault.
2. Add credential, server, and service entries.
3. Search, category filtering, and tag filtering.
4. Lock, unlock, and TOTP unlock.
5. Data retention after process kill and relaunch.
6. Import, export, backup, and restore.
7. Real WebDAV or S3 presigned URL sync.
8. iPhone portrait/landscape, iPad split view, Dynamic Type, dark mode, and basic VoiceOver accessibility.

### Release Build

The Xcode iOS app target now exists, and the local release gate creates a generic iOS archive and verifies the bundle id, version, arm64 app, privacy manifest, Assets.car, and dSYM. Before releasing an iOS app, finish Apple signing, device installation, and App Store Connect validation:

1. Set Apple Developer Team, release signing certificate, and provisioning profile in `PasswordManageriOS.xcodeproj`.
2. Confirm the final 1024x1024 app icon and asset catalog participate in the Release target.
3. Update display name, version, build number, deployment target, and the App Store Connect bundle id.
4. Configure required entitlements with least privilege; the current generic Keychain password item usage does not require an extra keychain access group.
5. Review `PrivacyInfo.xcprivacy`; `@AppStorage`/UserDefaults currently declares the `CA92.1` required reason, and any new required-reason API or data collection disclosure must be added here.
6. Select Generic iOS Device or Any iOS Device.
7. Product > Archive.
8. Validate the archive.
9. Upload to App Store Connect or export an Ad Hoc / Development build for QA.

Command-line archive example after the Xcode project exists:

```bash
xcodebuild archive \
  -project PasswordManageriOS.xcodeproj \
  -scheme PasswordManageriOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/PasswordManageriOS.xcarchive
```

The unsigned local archive contract is run by the release gate. Upload candidates must set `IOS_REQUIRE_SIGNED_ARCHIVE=true` and pass Apple signing before Validate archive / TestFlight.

### TestFlight / App Store Submission

1. Create an App ID in the Apple Developer account and enable required capabilities.
2. Create the app record in App Store Connect with bundle id, SKU, default language, and category.
3. Configure signing certificates and provisioning profiles, or use Xcode automatic signing.
4. Archive and upload a build.
5. Wait for processing in App Store Connect.
6. Configure TestFlight internal testing and validate install, setup, unlock, import/export, backup, sync, and relaunch flows.
7. Prepare privacy information: data collection, encryption usage, account/password-vault data handling, network sync behavior, and privacy policy URL.
8. Prepare screenshots, description, keywords, support URL, marketing URL, age rating, App Review notes, and demo account/steps if needed.
9. Submit for App Review.
10. After approval, choose manual or automatic release.

Official entry points:

- App Store Connect Help: https://developer.apple.com/help/app-store-connect/
- TestFlight: https://developer.apple.com/testflight/
- Distributing apps in Xcode: https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases

### Release Checklist

- [x] Native iOS directory is created under `apps/ios_native`.
- [x] SwiftPM core module builds.
- [x] README provides Chinese and English versions.
- [x] README documents development, release build, TestFlight, and App Store submission steps.
- [x] Core tests cover the crypto, TOTP, import/export, backup, and sync data-layer behavior already verified in the native macOS target.
- [x] Xcode iOS app target is created.
- [x] iOS bundle id, generated launch screen, empty entitlements, app icon asset, and UserDefaults privacy manifest are configured.
- [x] iOS simulator build/run is verified.
- [x] The local release gate installs and launches the Release app in an iOS simulator, verifying the bundle id, installation state, and launch screenshot.
- [x] The local release gate creates a generic iOS archive and verifies the arm64 app, Info.plist, privacy manifest, Assets.car, and dSYM.
- [ ] Apple Developer Team, release signing, device installation, and App Store/TestFlight upload validation are complete.
- [ ] iOS device install and baseline regression are verified.
- [ ] Real WebDAV/S3 end-to-end sync validation is complete.
- [ ] TestFlight internal testing install validation is complete.
- [ ] App Store Review is approved.
