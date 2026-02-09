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

### 4.1 测试可行性说明（macOS）
- **全量测试** 需要同时具备 `dart` 与 `flutter` 命令（Flutter SDK 已包含 Dart）
- **仅 Dart 包测试** 只需要 `dart` 命令（不依赖 Flutter）
- 如果提示 `dart: command not found`，说明尚未安装 Dart/Flutter 或未正确配置 PATH

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
