# DevEco 编译与真机验证手册（HarmonyOS 6）

更新时间：2026-07-28

## 1. 适用范围

用于 `apps/harmony_app` 的 DevEco 编译、安装、真机冒烟验证。

## 2. 先决条件

1. 安装 DevEco Studio（含 HarmonyOS SDK）。
2. 可用的 HarmonyOS 6 真机（已开启开发者模式与 USB 调试）。
3. 本仓库代码已拉取到本地。

官方文档入口：
- https://developer.huawei.com/consumer/cn/doc/
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-with-ets-stage
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-overview

## 3. 本地预检（命令行）

在仓库根目录执行：

```bash
./scripts/harmony_preflight.sh
```

预检通过后再进入 DevEco 编译。

推荐在发布前直接执行一键 release gate；默认会串联 preflight、清理旧产物、unsigned `assembleHap` 和 HAP metadata/signature 校验：

```bash
./scripts/harmony_verify_release.sh
```

## 3.1 当前命令行构建结果（2026-07-28）

已在本仓库执行：

```bash
./scripts/harmony_verify_release.sh
```

结果：
- `assembleHap` 成功
- 产物路径：`apps/harmony_app/entry/build/default/outputs/default/entry-default-unsigned.hap`
- 构建脚本已校验 HAP 的生产 bundleName、vendor、版本、权限和 unsigned 签名状态
- 字段关联专项测试已覆盖创建时目标分类/字段配置、候选过滤、九态详情以及原始 ID/目标秘密隔离
- 提示：当前未配置 `signingConfig`，需要在 DevEco 配置签名后生成可安装包

## 3.2 签名构建（命令行）

如需直接命令行生成 signed HAP，执行：

```bash
./scripts/harmony_verify_release.sh --signed
```

首次执行会自动生成 `apps/harmony_app/signing/signing.env` 模板；填写后再次执行即可。
脚本会先跑 unsigned gate，再生成 signed HAP，并要求 signed HAP 通过 `hap-sign-tool verify-app` 验签。只跑 signed gate 时可使用：

```bash
./scripts/harmony_verify_release.sh --skip-unsigned --signed
```

详见：`docs/SIGNING_SETUP.md`

## 4. DevEco 编译步骤

1. 打开 DevEco Studio，`Open` 项目目录：`apps/harmony_app`。
2. 等待 SDK 与索引同步完成。
3. 选择 `entry` 模块。
4. 执行 Build（Build Hap(s)/APP(s)）。
5. 确认产物生成（通常在 `entry/build/.../outputs/...` 下）。

## 5. 真机安装与启动

### 5.1 连接设备

```bash
hdc list targets
```

若未显示设备，请确认：
- USB 调试已开启
- 数据线可传输数据
- 设备授权弹窗已确认

### 5.2 安装 HAP

```bash
./scripts/harmony_install_hap.sh <你的hap路径> life.devops.passwordmanager
```

示例：

```bash
./scripts/harmony_install_hap.sh apps/harmony_app/entry/build/default/outputs/default/entry-default-signed.hap life.devops.passwordmanager
```

安装后可在设备桌面直接启动 App。

如需把 signed 构建与安装/启动 smoke 串在同一 release gate 中执行：

```bash
./scripts/harmony_verify_release.sh --signed --smoke
```

## 6. 冒烟测试用例（真机）

1. 首次启动，出现“初始化密码库”。
2. 输入主密码+确认，初始化成功。
3. 新建 3 类条目（账号/服务器/服务），列表显示正常。
4. 新建标签并应用到条目，搜索/标签筛选有效。
5. 锁定后重新解锁，数据仍存在。
6. 彻底关闭 App 后重启，数据仍存在（验证 Preferences 持久化）。
7. 输入错误主密码时，解锁失败且不崩溃。
8. 主密码解锁成功后启用生物识别解锁，锁定后通过“使用生物识别解锁”进入。
9. 新增或删除系统生物特征后，确认旧生物识别解锁凭据失效，并可用主密码重新启用。

### 6.1 字段关联回归

1. 创建目标分类“账号”，先新增文本字段“邮箱”；创建来源分类“服务器”时直接新增“字段关联”，在首次保存前选定“账号 / 邮箱”。确认无需先创建文本字段再改型。
2. 保存后重新进入分类编辑，确认来源字段 ID、`fieldReference` 类型、目标分类和稳定目标字段 ID 不丢失；另验证同分类可关联另一个文本字段，直接自引用被拒绝。
3. 创建账号目标条目和服务器来源条目，确认选择器只显示未删除且符合目标分类的候选；选择、更换和清空都能正常保存。
4. 依次验证 `EMPTY`、`INVALID_CONFIGURATION`、`MISSING`、`DELETED`、`CATEGORY_MISMATCH`、`TARGET_FIELD_MISSING`、`TARGET_FIELD_UNSUPPORTED`、`TARGET_FIELD_EMPTY`、`RESOLVED` 九态；确认按状态提供查看目标、重选、修复配置或清除操作。
5. `RESOLVED` 的已解锁显式详情只显示配置的目标字段名称和值；其他状态不得显示目标字段值。候选、摘要、搜索和日志不得包含目标字段值或原始 ID，剪贴板不得包含原始 ID、目标秘密或无关字段。
6. 删除配置中的目标分类，确认原目标分类文本仍显示并保留，不被改写成“未分类”；恢复相同目标后关系可重新解析。
7. 导入包含旧 `entryReference` 和未知 `valueType` 的模板，确认旧定义和值无损兼容、未知类型只读且扩展元数据不丢失，新建字段不再提供旧类型。
8. 锁定、杀进程并重启后重新解锁，确认关联配置、来源值和九态解析保持一致。
9. 执行单条/分类导出，确认不会因引用自动携带目标条目；执行同批复制导入时确认批内目标条目 ID 正确重映射而 `targetFieldId` 不变。
10. 如保险库来自旧 Flutter App，可验证历史数据迁入；创建字段关联后不得再使用旧 Flutter 版本写入同一同步保险库。

## 7. 日志采集建议

运行时日志可通过 `hdc shell hilog` 抓取；建议至少记录：
- 初始化
- 解锁成功/失败
- 条目新增/删除
- 异常栈

## 8. 当前已知限制

1. 命令行 `assembleHap` 已通过，但当前产物为 `unsigned`，真机安装前需在 DevEco 配置签名并生成可安装 HAP。
2. 当前未连接真机，`hdc list targets` 返回空，需要完成设备联机后再执行安装与冒烟回归。
3. 代码中保留了非 Harmony 环境的兜底加密分支，仅用于开发容错；发布前需确保设备侧走 `CryptoArchitectureKit` 主路径。
4. 生物识别解锁已通过 ArkTS 编译，但 Face/Fingerprint/HUKS token 的真实交互需要 signed HAP 安装到真机后验证。
