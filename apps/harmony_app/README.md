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
- 已支持单条/分类/全库 JSON 导出到用户选择位置并落盘为本地文件
- 已支持通过系统文件选择器导入单条/分类 JSON，并提供导入预览与冲突处理策略（保留副本/覆盖现有/跳过冲突）
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

## 全量重编译命令（从仓库根目录执行）

> 说明：用于“缓存可能脏、需要彻底重编译”的场景。  
> 默认 product 为 `default`。

### 1) 未签名 HAP 全量重编译

```bash
./scripts/harmony_preflight.sh
rm -rf apps/harmony_app/entry/build
./scripts/harmony_build_hap.sh default
```

产物通常位于：

`apps/harmony_app/entry/build/default/outputs/default/entry-default-unsigned.hap`

### 2) Signed HAP 全量重编译

```bash
./scripts/harmony_preflight.sh
rm -rf apps/harmony_app/entry/build
./scripts/harmony_build_signed_hap.sh
```

可选（使用自定义签名 env）：

```bash
./scripts/harmony_build_signed_hap.sh --env-file /absolute/path/to/signing.env
```

### 3) 安装到真机（已签名 HAP）

```bash
hdc list targets
./scripts/harmony_install_hap.sh apps/harmony_app/entry/build/default/outputs/default/entry-default-signed.hap com.example.passwordmanager
```

## 导入导出使用说明

### 导出

1. 解锁密码库后，在主列表中可导出：
   - 单条条目：在条目操作区触发“导出”
   - 分类：在分类管理区触发“导出分类”
   - 全库：在主页面触发“导出全部”
2. 系统会弹出保存位置选择器。
3. 导出文件为 `.json`，文件名会自动带上类型和时间戳。
4. 导出内容直接写入用户选择的本地位置。

### 导入

1. 在主页面选择“导入单条”或“导入分类”。
2. 通过系统文件选择器选择本地 `.json` 文件。
3. 导入前会展示预览摘要：
   - 新增数量
   - 重复数量
   - 冲突数量
4. 如果存在重复或冲突，可选择处理策略：
   - `保留副本`
   - `覆盖现有`
   - `跳过冲突`
5. 导入完成后会提示新增、更新、跳过的条目数量。

## 真机测试建议流程

1. 运行预检：`./scripts/harmony_preflight.sh`
2. 生成 HAP：
   - 未签名构建：`./scripts/harmony_build_hap.sh`
   - 已签名构建：`./scripts/harmony_build_signed_hap.sh`
3. 确认 `hdc list targets` 不再显示 `[Empty]`
4. 安装到设备：
   - `./scripts/harmony_install_hap.sh <signed_hap路径> com.example.passwordmanager`
5. 按 `docs/DEVECO_BUILD_AND_DEVICE_VALIDATION.md` 执行冒烟回归，重点覆盖：
   - 首次初始化与重新解锁
   - 条目/分类新增与持久化
   - 单条/分类/全库导出
   - 单条/分类导入、预览、冲突处理
   - 杀进程重启后的数据保留

## 当前验证结论

- 命令行预检与 `assembleHap` 已通过
- 当前环境 `hdc` 已可用，但设备列表为空，尚不能执行安装与真机回归
- 当前签名配置仍缺少 `HARMONY_SIGN_PROFILE` 与 `HARMONY_SIGN_CERTPATH`，无法生成可安装的 signed HAP

## 规范依据

- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-with-ets-stage
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-overview
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/app-configuration-file
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/module-configuration-file
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/declare-permissions
