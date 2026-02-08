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
- 安装 Flutter SDK（内含 Dart）
- 可选：安装 `melos` 以管理多包仓库
  - `dart pub global activate melos`

### 2. 安装依赖
如果使用 melos：
- `melos bootstrap`

不使用 melos（只跑 App）：
- `cd apps/flutter_app`
- `flutter pub get`

### 3. 运行应用
- `cd apps/flutter_app`
- `flutter run`

### 4. 测试
- `cd apps/flutter_app`
- `flutter test`

## 安全
详见 `SECURITY.md` 中的安全设计与实践。
