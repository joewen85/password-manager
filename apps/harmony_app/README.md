# harmony_app

鸿蒙 6（Stage 模型）密码管理器应用。

## 目录说明

- `AppScope/app.json5`: 应用级配置
- `entry/src/main/module.json5`: entry 模块配置
- `entry/src/main/ets/entryability/EntryAbility.ets`: UIAbility 入口
- `entry/src/main/ets/pages/Index.ets`: 主页面
- `entry/src/main/ets/src/model`: 领域模型
- `entry/src/main/ets/src/service`: 业务编排与状态

## 当前状态

- 已完成 Stage 工程骨架
- 已完成离线 MVP（主密码初始化/解锁、条目/标签管理、Preferences 持久化）
- 已切换到 `CryptoArchitectureKit` 显式加密路径（PBKDF2 + AES-GCM）
- 已完成同步状态机（WebDAV/S3、revision、冲突策略、同步日志）
- 已接入 2FA(TOTP) 与解锁失败限制（5 次失败锁定 5 分钟）
- 已完成权限最小化声明（`ohos.permission.INTERNET`）与隐私核查清单
- 已通过命令行 `assembleHap`（当前产物：`entry-default-unsigned.hap`）
- 待完成：签名产物生成、真机回归与发布核查

## 导入 DevEco Studio

1. 打开 DevEco Studio，选择 `Open`
2. 选择目录 `apps/harmony_app`
3. 使用 Stage 模型构建并运行 `entry` 模块

## 编译与真机验证

- 预检脚本：`./scripts/harmony_preflight.sh`
- 构建脚本：`./scripts/harmony_build_hap.sh [product]`
- 签名构建脚本：`./scripts/harmony_build_signed_hap.sh`
- 签名配置模板：`apps/harmony_app/signing/signing.env.example`
- 安装脚本：`./scripts/harmony_install_hap.sh <hap路径> com.example.passwordmanager`
- 操作手册：`docs/DEVECO_BUILD_AND_DEVICE_VALIDATION.md`
- 签名指南：`docs/SIGNING_SETUP.md`
- 结果模板：`docs/DEVICE_VALIDATION_RESULT_TEMPLATE.md`
- 加密兼容回归清单：`docs/CRYPTO_COMPATIBILITY_REGRESSION_CHECKLIST.md`
- 加密兼容结果模板：`docs/CRYPTO_COMPATIBILITY_RESULT_TEMPLATE.md`
- 加密兼容结果示例：`docs/CRYPTO_COMPATIBILITY_RESULT_SAMPLE.md`
- 加密兼容阻断报告模板：`docs/CRYPTO_COMPATIBILITY_BLOCKER_REPORT_TEMPLATE.md`
- 权限/隐私清单：`docs/PERMISSIONS_AND_PRIVACY_CHECKLIST.md`

## 规范依据

- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-with-ets-stage
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-overview
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/app-configuration-file
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/module-configuration-file
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions
