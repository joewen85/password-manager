# 跨平台密码管理器

一个跨平台密码管理器，用于保存用户名、密码、token、appid、access token、secret key。目标是构建安全、现代、可扩展的系统，覆盖 Windows、macOS、Linux、iOS、Android。

## 目标
- 所有敏感数据使用 AES‑256 加密
- 设备间自动同步（云 / NAS 支持）
- 2FA（TOTP）账户访问
- 加密备份
- 开源技术栈、可维护架构

## 项目结构
- `apps/flutter_app`: 跨平台 UI（Flutter）
- `packages/crypto`: AES‑256 加密服务
- `packages/storage`: 加密本地存储
- `packages/sync`: 云 / NAS 同步接口
- `packages/auth`: 2FA（TOTP）服务
- `packages/backup`: 加密备份服务
- `packages/core`: 领域模型与编排逻辑

## 开发步骤
### 1. 环境准备
- macOS 推荐安装方式：安装 Flutter SDK（内含 Dart），确保 `flutter` 与 `dart` 均可在终端直接使用
- 仅运行 Dart 包测试时：可只安装 Dart SDK（不含 Flutter）
- 可选：安装 `melos` 以管理多包仓库
  - `dart pub global activate melos`

### 1.1 跨平台安装步骤（开发环境）
下面以 **Flutter SDK（包含 Dart）** 为主；若只需要 Dart 测试，请替换为 Dart SDK 安装即可。

**macOS**
1) 通过官方渠道获取 Flutter SDK 压缩包并解压到本地目录（例如 `~/dev/flutter`）  
2) 将 `flutter/bin` 加入 PATH（如 `echo 'export PATH=\"$PATH:$HOME/dev/flutter/bin\"' >> ~/.zshrc`）  
3) 重新打开终端，执行 `flutter doctor` 校验环境  
4) 需要 iOS 调试时，安装 Xcode 并按 `flutter doctor` 提示完成配置  
5) **运行 macOS App 时提示 CocoaPods 错误**：  
   - 推荐：`brew install cocoapods`  
   - 备选：`sudo gem install cocoapods`  
   - 然后执行：`cd apps/flutter_app/macos && pod install`  

**Windows**
1) 通过官方渠道下载 Flutter SDK（zip），解压到本地目录（例如 `C:\\dev\\flutter`）  
2) 将 `C:\\dev\\flutter\\bin` 加入系统 PATH  
3) 打开新终端，执行 `flutter doctor` 校验环境  
4) 需要 Android 调试时，安装 Android Studio 并按 `flutter doctor` 提示配置 SDK  

**Linux**
1) 通过官方渠道下载 Flutter SDK（tar.xz），解压到本地目录（例如 `~/dev/flutter`）  
2) 将 `flutter/bin` 加入 PATH（如 `echo 'export PATH=\"$PATH:$HOME/dev/flutter/bin\"' >> ~/.bashrc`）  
3) 重新打开终端，执行 `flutter doctor` 校验环境  
4) 需要 Android 调试时，安装 Android Studio 并按 `flutter doctor` 提示配置 SDK  

### 2. 安装依赖
如果使用 melos：
- `melos bootstrap`

不使用 melos（只跑 App）：
- `cd apps/flutter_app`
- `flutter pub get`

### 3. 运行应用
- `cd apps/flutter_app`
- `flutter run`

#### 3.1 指定运行平台（可选）
- `flutter devices` 查看可用设备
- `flutter run -d macos`
- `flutter run -d windows`
- `flutter run -d linux`
- `flutter run -d ios`（需 Xcode / 真机或模拟器）
- `flutter run -d android`（需 Android SDK）

### 4. 测试
- `cd apps/flutter_app`
- `flutter test`

### 4.1 测试可行性说明（macOS）
- **全量测试** 需要同时具备 `dart` 与 `flutter` 命令（Flutter SDK 已包含 Dart）
- **仅 Dart 包测试** 只需要 `dart` 命令（不依赖 Flutter）
- 如果提示 `dart: command not found`，说明尚未安装 Dart/Flutter 或未正确配置 PATH
- macOS 测试在sandbox中运行，请勿将敏感数据保存在沙盒目录中.路径: `~/Library/Containers/com.example.passwordManagerApp/Data/Library/Application Support/`

### 4.1.1 发版版本号
1. 发版前修改 `apps/flutter_app/pubspec.yaml` 的 `version` 字段，格式为 `x.y.z+build`。
2. `x.y.z` 为对外版本号；`build` 为构建号，必须是整数，每次发版递增（Android 的 `versionCode` 由此生成）。
3. Flutter 构建时会自动注入版本到平台包信息中（Android: `versionName` / `versionCode`；iOS/macOS: `CFBundleShortVersionString` / `CFBundleVersion`，来源于 `Info.plist` 的 `FLUTTER_BUILD_NAME/NUMBER`）。
4. CI 或临时构建可用命令行覆盖，例如 `flutter build <platform> --build-name 1.2.3 --build-number 45`。

### 4.2 macOS 打包发布（App）
1) 安装并验证依赖  
   - `flutter doctor`  
   - 确保 CocoaPods 可用（见上方 macOS 步骤）  
2) 构建 Release 版本  
   - `cd apps/flutter_app`  
   - `flutter build macos --release`  
3) 产物位置  
   - `apps/flutter_app/build/macos/Build/Products/Release/password_manager_app.app`  
4)（可选）签名与公证  
   - 需 Apple 开发者账号、证书与 notarization  
   - 若需要分发给他人，建议签名与公证  

#### 4.2.1 签名与公证命令模板（示例）
> 以下示例仅作模板，请替换 `TEAM_ID`、`BUNDLE_ID`、`APPLE_ID`、`APP_SPECIFIC_PASSWORD`、证书名称等参数。

**准备：导出压缩包**
- `cd apps/flutter_app/build/macos/Build/Products/Release`
- `ditto -c -k --sequesterRsrc --keepParent password_manager_app.app password_manager_app.zip`

**签名（Developer ID Application）**
- `codesign --force --deep --options runtime --sign "Developer ID Application: YOUR_NAME (TEAM_ID)" password_manager_app.app`
- `codesign --verify --deep --strict --verbose=2 password_manager_app.app`

**公证（notarytool）**
- `xcrun notarytool submit password_manager_app.zip --apple-id "APPLE_ID" --team-id "TEAM_ID" --password "APP_SPECIFIC_PASSWORD" --wait`

**装订（staple）**
- `xcrun stapler staple password_manager_app.app`
- `spctl --assess --type execute --verbose=2 password_manager_app.app`

#### 4.2.2 使用 notarytool store-credentials（安全存储）
1) 保存凭据（只需一次）  
   - `xcrun notarytool store-credentials "AC_PROFILE" --apple-id "APPLE_ID" --team-id "TEAM_ID" --password "APP_SPECIFIC_PASSWORD"`
2) 提交公证（使用 profile）  
   - `xcrun notarytool submit password_manager_app.zip --keychain-profile "AC_PROFILE" --wait`

#### 4.2.3 通用 DMG 打包流程
1) 准备目录  
   - `mkdir -p dist/dmg`  
   - `cp -R password_manager_app.app dist/dmg/`  
2) 生成 DMG（基础版）  
   - `hdiutil create -volname "Password Manager" -srcfolder dist/dmg -ov -format UDZO dist/password_manager_app.dmg`
3)（可选）对 DMG 签名  
   - `codesign --force --sign "Developer ID Application: YOUR_NAME (TEAM_ID)" dist/password_manager_app.dmg`
4) 公证并装订 DMG（推荐）  
   - `xcrun notarytool submit dist/password_manager_app.dmg --keychain-profile "AC_PROFILE" --wait`  
   - `xcrun stapler staple dist/password_manager_app.dmg`

### 4.3 iOS 打包发布（App Store / TestFlight）
1) 依赖准备  
   - macOS + Xcode + CocoaPods  
   - `flutter doctor` 无报错  
2) 构建 Release  
   - `cd apps/flutter_app`  
   - `flutter build ipa --release`  
3) 产物位置  
   - `apps/flutter_app/build/ios/ipa/`  
4) 上架说明  
   - 需 Apple 开发者账号、Bundle ID、证书、Provisioning Profile  
   - 通过 Xcode / Transporter 上传到 App Store Connect  

### 4.4 Android 打包发布（APK / AAB）
1) 依赖准备  
   - 安装 Android Studio / SDK / NDK  
   - `flutter doctor` 无报错  
2) 构建 APK（直接安装）  
   - `cd apps/flutter_app`  
   - `flutter build apk --release`  
3) 构建 AAB（上架推荐）  
   - `cd apps/flutter_app`  
   - `flutter build appbundle --release`  
4) 产物位置  
   - APK: `apps/flutter_app/build/app/outputs/flutter-apk/`  
   - AAB: `apps/flutter_app/build/app/outputs/bundle/release/`  
5) 签名说明  
   - Release 需配置 keystore 与签名信息（Android 官方流程）  

### 4.5 Windows 打包发布（桌面）
1) 依赖准备  
   - Windows 10/11  
   - Visual Studio（安装 “Desktop development with C++”）  
   - `flutter doctor` 无报错  
2) 构建 Release  
   - `cd apps/flutter_app`  
   - `flutter build windows --release`  
3) 产物位置  
   - `apps/flutter_app/build/windows/runner/Release/`  

### 4.6 Linux 打包发布（桌面）
1) 依赖准备  
   - 参考 Flutter Linux 依赖：clang、cmake、ninja、pkg-config、gtk 等  
   - `flutter doctor` 无报错  
2) 构建 Release  
   - `cd apps/flutter_app`  
   - `flutter build linux --release`  
3) 产物位置  
   - `apps/flutter_app/build/linux/x64/release/`  

### 4.7 Web 打包发布
1) 构建 Release  
   - `cd apps/flutter_app`  
   - `flutter build web --release`  
2) 产物位置  
   - `apps/flutter_app/build/web/`  

### 5. 全量测试（推荐）
- macOS/Linux：`./scripts/test_all.sh`
- Windows：`powershell -ExecutionPolicy Bypass -File .\\scripts\\test_all.ps1`

### 6. 仅 Dart 包测试（无 Flutter）
- macOS/Linux：`./scripts/test_dart_only.sh`
- Windows：`powershell -ExecutionPolicy Bypass -File .\\scripts\\test_dart_only.ps1`

## 分步开发计划（里程碑）
### 阶段 1：MVP（本地离线 + 基础加密）
**迭代 1.1：数据模型与加密管线**
- 定义 VaultItem / CredentialPayload 数据结构
- AES‑256‑GCM 加密/解密实现
- 密钥派生（PBKDF2）与盐存储格式
- 加解密一致性测试

**迭代 1.2：本地存储与仓库实现**
- 本地加密存储实现（文件 / SQLite 二选一）
- VaultRepository 具体实现
- 基础 CRUD 测试

**迭代 1.3：基础 UI**
- 新增/查看条目 UI
- 表单校验与字段遮罩
- 列表展示与详情弹窗

### 阶段 2：同步与备份
**迭代 2.1：同步接口落地**
- 选定一个同步后端（WebDAV / S3 / NAS）
- 实现上传/下载流程
- 同步状态与错误处理

**迭代 2.2：冲突处理**
- 冲突检测策略（时间戳 / 版本号）
- 冲突合并规则与 UI 提示

**迭代 2.3：备份**
- 定期加密备份
- 恢复流程与备份校验

### 阶段 3：认证与安全强化
**迭代 3.1：2FA**
- TOTP 绑定、二维码展示
- TOTP 验证流程

**迭代 3.2：防护措施**
- 解锁失败限流
- 审计日志（本地）

**迭代 3.3：密钥轮换**
- 密钥轮换流程
- 数据迁移与版本升级

### 阶段 4：体验与平台优化
**迭代 4.1：全端适配**
- Windows/macOS/Linux/iOS/Android 适配测试
- 平台权限与安全存储适配

**迭代 4.2：体验优化**
- 搜索、过滤与排序
- 列表性能优化（分页/虚拟列表）

**迭代 4.3：无障碍与主题**
- 多主题支持
- 无障碍支持（大字体/语义标签）

## 安全
详见 `SECURITY.md` 中的安全设计与实践。
