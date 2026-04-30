# 鸿蒙版（HarmonyOS 6）迁移与实施计划

更新时间：2026-03-01

## 1. 目标与范围（基于当前仓库功能）

当前 Flutter 版已实现能力（本次鸿蒙版需对齐）：
- 主密码初始化/解锁（可选 2FA TOTP）
- 密码库三类条目：账号凭据（credential）、服务器（server）、服务（service）
- 条目新增/编辑/删除（软删除）、详情查看、复制
- 标签体系：新建、重命名、删除、搜索过滤
- 本地加密存储（AES-GCM + PBKDF2 派生）
- 同步设置：WebDAV / NAS WebDAV / S3 预签名 URL
- 冲突策略：remoteWins / localWins / keepBoth
- 密文导出、同步日志与状态

本阶段范围：
- 先交付鸿蒙 6 Stage 模型工程骨架 + 本地离线可运行 MVP（解锁、列表、新增/编辑/删除、标签）。
- 再补齐同步、冲突处理、导出、2FA 与安全加固。

## 2. 鸿蒙 6 规范约束（必须遵循）

1. 工程形态：使用 Stage 模型（UIAbility），不使用 FA 旧模型。
2. 语言与 UI：ArkTS + ArkUI 声明式开发。
3. 配置规范：`AppScope/app.json5`、`entry/src/main/module.json5`、`build-profile.json5` 按官方结构组织。
4. 权限规范：在 `module.json5` 声明、按需申请、最小权限原则。
5. 数据与安全：本地数据加密存储，密钥派生与加密算法与现有项目保持一致（PBKDF2 + AES-GCM）。
6. 网络：仅 HTTPS，同步接口做超时、重试、状态码与错误分级处理。

## 3. 官方文档映射（华为文档中心）

> 说明：以下均为华为开发者官方文档入口或其下对应指南，用于本计划的强约束依据。

- 文档中心入口：https://developer.huawei.com/consumer/cn/doc/
- Stage 模型开发总览：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-with-ets-stage
- 快速开始与工程结构入口：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-overview
- ArkTS 语言入口：https://developer.huawei.com/consumer/cn/arkts/
- ArkUI 框架入口：https://developer.huawei.com/consumer/cn/arkui/
- 应用配置（app.json5）指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/app-configuration-file
- 模块配置（module.json5）指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/module-configuration-file
- 权限声明与申请指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions

## 4. 里程碑计划与执行状态

### M0 功能盘点与迁移设计
- [x] 盘点当前 Flutter 功能、数据模型、加密/同步流程
- [x] 输出鸿蒙迁移目标清单与阶段范围
- 验收：`harmoony-plan.md` 形成可执行清单（已完成）

### M1 建立鸿蒙 6 Stage 工程骨架
- [x] 新建 `apps/harmony_app` 目录结构
- [x] 补齐 `app.json5 / module.json5 / build-profile.json5 / pages` 等文件
- [x] 建立 UIAbility 与页面路由
- 验收：工程结构符合 Stage 规范，可在 DevEco 导入（已完成）

### M2 本地离线 MVP（核心功能）
- [x] ArkTS 领域模型（credential/server/service/tag）
- [x] 主密码初始化、解锁与会话状态
- [x] 本地密文存储仓库（已接入 Preferences 持久化 + 密文 envelope）
- [x] 条目 CRUD、标签管理、搜索过滤
- 验收：离线功能闭环（持久化版）已完成

### M3 加密体系对齐
- [x] PBKDF2 参数对齐（迭代次数 120000、salt 16 bytes）
- [x] AES-GCM 密文结构对齐（ciphertext/nonce/mac/version）
- [x] 主密钥记录与 metadata 密钥策略迁移
- [x] `CryptoArchitectureKit` 显式实现接入（PBKDF2 + AES-GCM）
- 验收：代码层已完成；待 DevEco 真机与 Flutter 兼容数据验证

### M4 同步能力迁移
- [x] WebDAV/NAS WebDAV 客户端（ArkTS 同步层已迁移）
- [x] S3 预签名 URL 客户端（ArkTS 同步层已迁移）
- [x] 修订号、冲突策略、同步日志（已接入控制器与页面）
- 验收：同步状态机已接入；待真机联调远端服务

### M5 安全与发布
- [x] 2FA(TOTP) 与安全策略（失败限制、日志脱敏）
- [x] 权限与隐私声明核查
- [x] DevEco 命令行构建（`assembleHap`）与工程配置对齐
- [ ] 真机联调、发布材料
- [x] DevEco 编译/真机验证脚本与手册（可在本机直接执行）
- 验收：达到可提测版本

## 5. 本次会话执行清单（按计划分步推进）

1. [x] M0：完成功能盘点并固化本计划
2. [x] M1：创建鸿蒙 Stage 工程骨架
3. [x] M2：实现本地离线 MVP（解锁+条目 CRUD+标签+持久化）
4. [x] M3：对齐并接入加密实现（代码完成，待设备侧验证）
5. [x] M4：同步能力迁移（WebDAV/S3 + 状态机 + 冲突策略 + 同步日志）
6. [x] M5(阶段一)：2FA(TOTP) + 解锁失败限制 + 同步日志脱敏
7. [x] M5(阶段二)：权限最小化声明 + 隐私核查清单
8. [x] M3补充：`CryptoArchitectureKit` 显式实现替换 WebCrypto 主路径
9. [x] M3补充：加密兼容性回归清单（Flutter 旧数据 -> Harmony 解密 -> 再同步）
10. [x] M3补充：加密兼容性回归结果模板（执行填写版）
11. [x] M3补充：加密兼容性结果示例（填写口径样例）
12. [x] M3补充：加密兼容性阻断问题报告模板
13. [x] M5补充：修复 HarmonyOS 6 build-profile/hvigor 配置并通过命令行 `assembleHap`
14. [x] M5补充：签名构建脚本与签名接入文档（`harmony_build_signed_hap.sh` + `SIGNING_SETUP.md`）
15. [x] M5补充：签名脚本支持 `signing.env` 自动生成/加载与缺失项诊断

## 6. 风险与处理

- 风险：当前仅完成命令行 `assembleHap`（产物为 `entry-default-unsigned.hap`），尚未完成签名产物安装与真机回归。
- 处理：在 DevEco Studio 配置签名并生成可安装 HAP，随后执行 `scripts/harmony_install_hap.sh` 与真机冒烟清单回填。
- 风险：`CryptoArchitectureKit` 已接入并可编译，但尚未完成 Flutter 历史密文的设备侧兼容回归。
- 处理：按 `apps/harmony_app/docs/CRYPTO_COMPATIBILITY_REGRESSION_CHECKLIST.md` 完整执行并回填结果模板。
