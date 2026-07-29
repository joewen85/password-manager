# Password Manager HarmonyOS Native

## 中文

该目录包含 HarmonyOS 6 原生应用，用于继续补齐 HarmonyOS 原生端能力。

### 范围

- 使用 HarmonyOS Stage 模型和 ArkTS 实现原生应用。
- 已完成 Stage 工程骨架、UIAbility 入口、主页面和应用级配置。
- 已完成离线 MVP：主密码初始化/解锁、条目/标签管理、Preferences 持久化。
- 已切换到 `CryptoArchitectureKit` 显式加密路径：PBKDF2 + AES-GCM。
- PBKDF2 默认参数已对齐 Dart/Android/macOS/iOS 契约：新建 HarmonyOS 原生保险库使用 600000 次迭代；旧保险库继续按记录中的迭代次数解锁。
- 已完成同步状态机：WebDAV/S3、revision、冲突策略和同步日志。
- 已接入 2FA(TOTP) 与解锁失败限制：5 次失败后锁定 5 分钟。
- 已接入生物识别解锁：主密码凭据使用 HUKS AES-GCM 硬件密钥加密，解密需要 Face/Fingerprint 认证 token，新增生物特征后密钥失效。
- 已支持单条、分类、全库 JSON 导出到用户选择位置并落盘为本地文件。
- 已支持通过系统文件选择器导入单条/分类 JSON，并提供导入预览与冲突处理策略：保留副本、覆盖现有、跳过冲突。
- 字段关联已完成首个完整 UI 垂直切片：分类字段可选择“文本/关联条目”和可选目标分类，条目编辑可按约束选择、更换或清空目标，详情覆盖未选择、正常、缺失、已删除、分类不匹配五态并提供查看或修复入口。已有存值的模板字段禁止静默改型或删除；孤儿绑定和未知类型只读保留。候选、详情、摘要和搜索只使用安全目标投影，不显示、复制或索引原始引用 ID 与目标秘密；标签职责不变。格式与上线顺序见 `../../docs/FIELD_REFERENCE_CONTRACT.md`。
- 字段到字段关联已推进到 P8：除在 `FieldTemplate.targetFieldId` 中无损保留目标字段 ID 外，内部 resolver 已实现九态解析、目标文本字段安全投影、legacy 空绑定名称回退、搜索安全投影、复制导入目标条目 ID 重映射、分类改名传播和目标字段删除/改型保护。非空字段 ID 始终按大小写敏感的不透明 ID 精确匹配；`fieldReference` 创建、编辑和详情 UI 仍未开放，数据 API 见 `docs/FIELD_REFERENCE_API.md`。
- 已完成权限最小化声明：`ohos.permission.INTERNET`、`ohos.permission.ACCESS_BIOMETRIC`。
- 已提供权限/隐私清单、签名指南、DevEco 编译与真机验证手册，以及 Flutter 旧数据到 Harmony 端的加密兼容回归清单。
- 当前命令行预检与 `assembleHap` 已验证通过，产物为 `entry-default-unsigned.hap`。
- HAP 构建链路会通过 `scripts/harmony_verify_hap.sh` 结构化校验 `pack.info` / `module.json` 的生产 bundleName、vendor、版本和权限；unsigned 构建会拒绝误签名包，signed 构建会要求 Harmony `hap-sign-tool` 验签通过。
- 生产发布前仍需完成 signed HAP 生成、真机回归、真实同步服务兼容验证、权限/隐私最终核查和 AppGallery 上架核查。

### 目录说明

- `AppScope/app.json5`: 应用级配置。
- `entry/src/main/module.json5`: entry 模块配置。
- `entry/src/main/ets/entryability/EntryAbility.ets`: UIAbility 入口。
- `entry/src/main/ets/pages/Index.ets`: 主页面。
- `entry/src/main/ets/src/model`: 领域模型。
- `entry/src/main/ets/src/service`: 业务编排与状态。
- `docs/DEVECO_BUILD_AND_DEVICE_VALIDATION.md`: DevEco 编译与真机验证手册。
- `docs/SIGNING_SETUP.md`: signed HAP 生成指南。
- `docs/PERMISSIONS_AND_PRIVACY_CHECKLIST.md`: 权限与隐私核查清单。
- `docs/FIELD_REFERENCE_API.md`: 字段到字段关联数据 API 与兼容规则。
- `docs/CRYPTO_COMPATIBILITY_REGRESSION_CHECKLIST.md`: 加密兼容回归清单。
- `docs/DEVICE_VALIDATION_RESULT_TEMPLATE.md`: 设备验证结果模板。

### 环境要求

- DevEco Studio，含 HarmonyOS SDK。
- HarmonyOS 6 真机，开启开发者模式和 USB 调试。
- `node` / `npm` 可用，因为 Hvigor 构建链路依赖 Node 工具链。
- `hdc` 可用并可列出设备。

本地预检：

```bash
./scripts/harmony_preflight.sh
```

字段到字段关联数据契约专项测试：

```bash
node scripts/harmony_field_reference_contract_compat_tests.mjs
node scripts/harmony_reference_resolver_tests.mjs
```

推荐的一键发布门禁默认执行 preflight、清理旧产物、unsigned build 和 HAP 校验：

```bash
./scripts/harmony_verify_release.sh
```

### 开发

在 DevEco Studio 中打开：

```text
apps/harmony_app
```

选择 `entry` 模块后运行或构建 HAP。

命令行未签名构建：

```bash
./scripts/harmony_verify_release.sh
```

产物通常位于：

```text
apps/harmony_app/entry/build/default/outputs/default/entry-default-unsigned.hap
```

单独验证 HAP metadata 和签名状态：

```bash
./scripts/harmony_verify_hap.sh --expect-signature unsigned \
  apps/harmony_app/entry/build/default/outputs/default/entry-default-unsigned.hap
```

### 本地功能验证

每次修改 HarmonyOS 原生端后，至少覆盖以下流程：

1. 使用 DevEco Studio 或命令行生成 HAP。
2. 使用 signed HAP 安装到 HarmonyOS 6 真机。
3. 首次启动，初始化密码库。
4. 新增 credential、server、service 三类条目。
5. 新增标签，验证搜索/标签筛选有效。
6. 锁定并重新解锁，确认数据仍存在。
7. 杀进程后重启，再次解锁并确认数据仍存在。
8. 输入错误主密码，确认失败计数与 5 次失败锁定 5 分钟行为正常。
9. 启用 TOTP，验证缺失/错误验证码被拒绝，当前验证码可通过。
10. 使用主密码成功解锁后启用生物识别解锁，锁定 App，再用“使用生物识别解锁”进入。
11. 新增或删除系统生物特征后，验证旧生物解锁凭据失效并需要主密码重新启用。
12. 执行单条、分类、全库 JSON 导出，确认文件写入用户选择的位置。
13. 执行单条/分类 JSON 导入，确认预览、保留副本、覆盖现有、跳过冲突策略符合预期。
14. 新建未使用的分类模板字段，分别验证“文本/关联条目”切换、“不限分类”和指定目标分类；字段一旦已有存值，删除和类型切换应被阻止，名称及关联范围仍可安全修改；未知字段类型应保持只读且配置不丢失。
15. 新建或编辑条目，验证关联候选只包含未删除且符合目标分类的记录，并验证选择、更换、清空和重启后的数据保真。
16. 分别制造未选择、正常、缺失、已删除、分类不匹配五态，验证详情文案、查看目标和修复入口。
17. 用引用 ID、目标密码、Token、Secret 和备注搜索，确认列表、详情、摘要、搜索和剪贴板不泄露这些值。
18. 执行 WebDAV 或 S3 同步，确认 revision、冲突策略和同步日志符合当前跨端契约。
19. 按 `docs/CRYPTO_COMPATIBILITY_REGRESSION_CHECKLIST.md` 验证 Flutter 历史数据可迁移到 Harmony；创建字段关联后不得再使用旧 Flutter 写入同一保险库。

### 签名构建

首次准备签名材料：

1. 在 DevEco Studio 或 AppGallery Connect 中准备发布签名材料。
2. 准备以下文件和密钥信息：
   - `storeFile`，例如 `.p12`。
   - `profile`。
   - `certpath`。
   - `storePassword`。
   - `keyAlias`。
   - `keyPassword`。
3. 不要把真实签名材料、密码或 profile 提交到 Git。

生成 env 模板：

```bash
./scripts/harmony_build_signed_hap.sh
```

编辑：

```text
apps/harmony_app/signing/signing.env
```

或使用外部 env 文件：

```bash
./scripts/harmony_build_signed_hap.sh --env-file /absolute/path/to/signing.env
```

构建 signed HAP：

```bash
./scripts/harmony_verify_release.sh --signed
```

`harmony_verify_release.sh --signed` 会先跑 unsigned gate，再生成 signed HAP 并要求新产物通过 `hap-sign-tool verify-app` 验签；如需只跑 signed gate，可使用 `--skip-unsigned --signed`。外部签名 env 仍可通过 `--env-file /absolute/path/to/signing.env` 传入。

### 真机安装

确认设备：

```bash
hdc list targets
```

安装：

```bash
./scripts/harmony_install_hap.sh \
  apps/harmony_app/entry/build/default/outputs/default/entry-default-signed.hap \
  life.devops.passwordmanager
```

安装后优先运行安装/启动 smoke：

```bash
./scripts/harmony_verify_release.sh --signed --smoke
```

该脚本会在连接设备上执行安装、`aa start -b` 启动、抓取 `hilog` 中的首屏启动信号，并在结束后卸载包。然后按 `docs/DEVECO_BUILD_AND_DEVICE_VALIDATION.md` 执行真机冒烟回归，并使用 `docs/DEVICE_VALIDATION_RESULT_TEMPLATE.md` 记录结果。

### AppGallery 上架

1. 在华为开发者平台进入 AppGallery Connect。
2. 创建或选择应用，确认包名、应用名称、分类、支持设备、语言、国家/地区和应用 ID。
3. 配置 HarmonyOS 应用签名、profile 和发布证书；确保 signed HAP 使用发布材料而非 debug 材料。
4. 更新版本号、版本名、应用图标、截图、隐私政策 URL、客服/支持联系方式和应用介绍。
5. 完成隐私与权限披露，重点说明本应用保存加密密码库数据、使用网络同步、使用加密能力，并最小化权限。
6. 上传 signed HAP。
7. 先走测试或灰度发布通道，完成安装、初始化、解锁、导入导出、同步和重启回归。
8. 根据审核反馈修正 metadata、权限说明、隐私政策或包体问题。
9. 验证通过后提交正式发布。
10. Release notes 只描述用户可见能力，不要把未验证或未完成的原生等价工作写成已发布能力。

官方入口：

- HarmonyOS 开发入口：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-overview
- Stage 模型入门：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-with-ets-stage
- AppGallery Connect：https://developer.huawei.com/consumer/cn/service/josp/agc/index.html
- AppGallery：https://developer.huawei.com/consumer/cn/appgallery/

### 发布检查清单

- [x] 原生 Stage 工程骨架已建立。
- [x] 离线 MVP 支持初始化、解锁、条目/标签管理和 Preferences 持久化。
- [x] 已接入 `CryptoArchitectureKit` PBKDF2 + AES-GCM 加密路径。
- [x] 已接入 TOTP 和失败锁定策略。
- [x] 已接入 HUKS 硬件密钥保护的生物识别解锁。
- [x] 已实现 WebDAV/S3 同步状态机、revision、冲突策略和同步日志。
- [x] 已实现单条、分类、全库 JSON 导出。
- [x] 已实现单条/分类 JSON 导入、预览和冲突策略。
- [x] 已实现字段关联分类配置、条目选择/清空、五态详情和修复入口。
- [x] 字段关联专项合同测试、ArkTS 编译与 unsigned HAP 构建已通过。
- [x] 已配置生产 bundleName/vendor metadata，并与 Android applicationId 对齐为 `life.devops.passwordmanager`。
- [x] `harmony_preflight.sh` 和 HAP 构建脚本会校验生产 metadata 与无横杠 bundleName，防止回退到 example 或非法包名。
- [x] HAP verifier 会结构化校验生产 metadata/权限，并区分 unsigned 与 signed 产物。
- [x] 已提供一键发布门禁脚本，串联 preflight、unsigned/signed build、HAP verify 和可选真机 smoke。
- [x] 权限声明保持最小化，目前声明 `ohos.permission.INTERNET` 与 `ohos.permission.ACCESS_BIOMETRIC`。
- [x] 已提供 DevEco 编译、签名、真机验证、权限隐私、加密兼容回归文档。
- [x] 已提供安装/启动 smoke 脚本，会在连接设备上安装、启动、抓取首屏日志并卸载 HAP。
- [ ] signed HAP 已用发布签名材料生成。
- [ ] signed HAP 已安装到 HarmonyOS 6 真机。
- [ ] 真机冒烟回归完成并记录到结果模板。
- [ ] Flutter 历史数据到 Harmony 的只读迁移兼容回归完成；已确认创建关联后不再使用旧 Flutter 写回。
- [ ] WebDAV/S3 真实服务端到端同步验证完成。
- [ ] AppGallery Connect metadata、隐私政策、权限说明、截图和发布说明已准备。
- [ ] AppGallery 测试/灰度通道安装验证完成。
- [ ] 正式上架审核通过。

### 当前验证结论

- 命令行预检与 `assembleHap` 已通过，当前产物为 `entry-default-unsigned.hap`；HAP 内 `pack.info` / `module.json` 的生产 metadata、权限和 unsigned 状态已通过脚本校验。
- 字段关联专项测试已覆盖模板类型/目标分类、已用字段改型/删除门禁、分类往返字段复用、UUID、未知/孤儿类型保真、候选过滤、五态解析，以及详情、摘要、搜索和剪贴板的原始 ID/目标秘密隔离。
- 生物识别解锁代码已通过 ArkTS 编译；真机上的 Face/Fingerprint/HUKS token 流程仍需安装 signed HAP 后验证。
- 当前环境 `hdc` 曾可用，但设备列表为空，尚不能执行安装与真机回归。
- 当前签名配置仍缺少 `HARMONY_SIGN_PROFILE` 与 `HARMONY_SIGN_CERTPATH`，无法生成可安装 signed HAP。

---

## English

This directory contains the native HarmonyOS 6 application target, used to build HarmonyOS-native parity incrementally.

### Scope

- Native HarmonyOS app implemented with the Stage model and ArkTS.
- Stage project scaffold, UIAbility entry point, main page, and app-level configuration are in place.
- Offline MVP is implemented: master password setup/unlock, entry/tag management, and Preferences persistence.
- Explicit `CryptoArchitectureKit` encryption path is wired: PBKDF2 + AES-GCM.
- PBKDF2 defaults match the Dart/Android/macOS/iOS contract: new native HarmonyOS vaults use 600000 iterations; existing vaults continue to unlock with the iterations stored in their records.
- Sync state machine is implemented for WebDAV/S3, revisions, conflict strategy, and sync logs.
- TOTP-based 2FA and unlock throttling are implemented: 5 failed attempts lock the vault for 5 minutes.
- Biometric unlock is implemented: the master-password credential is encrypted by a HUKS AES-GCM hardware key and decryption requires a Face/Fingerprint authentication token. The key is invalidated when new biometric credentials are enrolled.
- Item, category, and full-vault JSON export to a user-selected local location is implemented.
- Item/category JSON import through the system picker is implemented with import preview and conflict strategies: keep copy, overwrite existing, and skip conflicts.
- Entry references now provide the first complete UI vertical slice. Category fields can choose text or entry-reference behavior plus an optional target category; entry editing can select, replace, or clear a matching target; details cover empty, resolved, missing, deleted, and category-mismatch states with open and repair actions. Candidates, details, summaries, and search use only the safe target projection and never display, copy, or index the stored reference ID or target secrets. Tags remain unchanged. See `../../docs/FIELD_REFERENCE_CONTRACT.md` for the format and rollout order.
- Field-to-field references have reached P8. In addition to losslessly preserving `FieldTemplate.targetFieldId`, the internal resolver now implements nine states, a minimal safe text-field projection, legacy empty-binding name fallback, safe search projection, copied-import target-entry ID remapping, category-rename propagation, and target-field deletion/retyping protection. Non-empty field IDs always use exact case-sensitive opaque-ID matching. Creation, editing, and detail UI for `fieldReference` remain unavailable; see `docs/FIELD_REFERENCE_API.md`.
- Permission declaration is minimized to `ohos.permission.INTERNET` and `ohos.permission.ACCESS_BIOMETRIC`.
- Documentation exists for permissions/privacy review, signing, DevEco build and device validation, and historical Flutter-to-Harmony migration compatibility regression.
- Command-line preflight and `assembleHap` have passed and produced `entry-default-unsigned.hap`.
- The HAP build flow runs `scripts/harmony_verify_hap.sh` to validate production bundleName, vendor, version, and permissions from `pack.info` / `module.json`; unsigned builds reject accidentally signed artifacts, and signed builds require Harmony `hap-sign-tool` verification to pass.
- Signed HAP generation, device regression, real sync-service compatibility validation, final permissions/privacy review, and AppGallery submission validation remain required before production release.

### Directory Layout

- `AppScope/app.json5`: app-level configuration.
- `entry/src/main/module.json5`: entry module configuration.
- `entry/src/main/ets/entryability/EntryAbility.ets`: UIAbility entry point.
- `entry/src/main/ets/pages/Index.ets`: main page.
- `entry/src/main/ets/src/model`: domain model.
- `entry/src/main/ets/src/service`: business orchestration and state.
- `docs/DEVECO_BUILD_AND_DEVICE_VALIDATION.md`: DevEco build and device validation guide.
- `docs/SIGNING_SETUP.md`: signed HAP generation guide.
- `docs/PERMISSIONS_AND_PRIVACY_CHECKLIST.md`: permissions and privacy checklist.
- `docs/FIELD_REFERENCE_API.md`: field-to-field reference data API and compatibility rules.
- `docs/CRYPTO_COMPATIBILITY_REGRESSION_CHECKLIST.md`: crypto compatibility regression checklist.
- `docs/DEVICE_VALIDATION_RESULT_TEMPLATE.md`: device validation result template.

### Requirements

- DevEco Studio with the HarmonyOS SDK.
- HarmonyOS 6 device with developer mode and USB debugging enabled.
- `node` / `npm`, because the Hvigor build chain depends on Node tooling.
- `hdc` available and able to list the target device.

Local preflight:

```bash
./scripts/harmony_preflight.sh
```

Field-to-field reference data contract test:

```bash
node scripts/harmony_field_reference_contract_compat_tests.mjs
node scripts/harmony_reference_resolver_tests.mjs
```

The recommended one-command release gate runs preflight, clears stale build outputs, then performs unsigned build and HAP verification by default:

```bash
./scripts/harmony_verify_release.sh
```

### Develop

Open this directory in DevEco Studio:

```text
apps/harmony_app
```

Select the `entry` module, then run or build the HAP.

Unsigned command-line build:

```bash
./scripts/harmony_verify_release.sh
```

The artifact is usually generated at:

```text
apps/harmony_app/entry/build/default/outputs/default/entry-default-unsigned.hap
```

Verify HAP metadata and signature state directly:

```bash
./scripts/harmony_verify_hap.sh --expect-signature unsigned \
  apps/harmony_app/entry/build/default/outputs/default/entry-default-unsigned.hap
```

### Local Feature Verification

After changing the native HarmonyOS app, cover at least this flow:

1. Build a HAP with DevEco Studio or the command-line script.
2. Install a signed HAP on a HarmonyOS 6 device.
3. Launch for the first time and initialize the vault.
4. Add credential, server, and service entries.
5. Add a tag, then verify search and tag filtering.
6. Lock and unlock again, confirming data remains available.
7. Kill the app process, relaunch, unlock, and confirm data remains available.
8. Enter wrong master passwords and verify the failure count plus the 5-minute lockout after 5 failures.
9. Enable TOTP and verify missing/invalid codes fail while the current code succeeds.
10. After a successful master-password unlock, enable biometric unlock, lock the app, then unlock with the biometric button.
11. Add or remove an enrolled system biometric credential and verify the old biometric-unlock credential is invalidated and must be re-enabled with the master password.
12. Export item, category, and full-vault JSON files and confirm they are written to the user-selected location.
13. Import item/category JSON files and verify preview, keep-copy, overwrite-existing, and skip-conflict behavior.
14. Create category template fields and verify text/reference switching, unrestricted and specific target categories, plus read-only preservation of unknown field types.
15. Create or edit entries and verify candidates include only live matching records, then verify select, replace, clear, restart, and persistence behavior.
16. Exercise empty, resolved, missing, deleted, and category-mismatch states and verify detail copy, open-target, and repair actions.
17. Search for stored reference IDs and target passwords, tokens, secrets, and notes; verify lists, details, summaries, search, and clipboard never expose them.
18. Run WebDAV or S3 sync and confirm revisions, conflict strategy, and sync logs match the current cross-platform contract.
19. Use `docs/CRYPTO_COMPATIBILITY_REGRESSION_CHECKLIST.md` to verify historical Flutter data can migrate into HarmonyOS; after creating references, do not use a legacy Flutter build to write the same vault.

### Signed Build

Prepare release signing materials:

1. Prepare release signing materials in DevEco Studio or AppGallery Connect.
2. Collect these files and secrets:
   - `storeFile`, such as a `.p12` file.
   - `profile`.
   - `certpath`.
   - `storePassword`.
   - `keyAlias`.
   - `keyPassword`.
3. Never commit real signing materials, passwords, or profiles to Git.

Generate the env template:

```bash
./scripts/harmony_build_signed_hap.sh
```

Edit:

```text
apps/harmony_app/signing/signing.env
```

Or use an external env file:

```bash
./scripts/harmony_build_signed_hap.sh --env-file /absolute/path/to/signing.env
```

Build a signed HAP:

```bash
./scripts/harmony_verify_release.sh --signed
```

`harmony_verify_release.sh --signed` runs the unsigned gate first, then builds the signed HAP and requires the new artifact to pass `hap-sign-tool verify-app`. Use `--skip-unsigned --signed` to run only the signed gate. External signing env files are still supported with `--env-file /absolute/path/to/signing.env`.

### Device Install

Check devices:

```bash
hdc list targets
```

Install:

```bash
./scripts/harmony_install_hap.sh \
  apps/harmony_app/entry/build/default/outputs/default/entry-default-signed.hap \
  life.devops.passwordmanager
```

Then run the smoke regression in `docs/DEVECO_BUILD_AND_DEVICE_VALIDATION.md` and record the result with `docs/DEVICE_VALIDATION_RESULT_TEMPLATE.md`.

### AppGallery Submission

1. Open AppGallery Connect from the Huawei Developer platform.
2. Create or select the app, then confirm package name, app name, category, supported devices, languages, countries/regions, and app ID.
3. Configure HarmonyOS app signing, profile, and release certificate. Ensure the signed HAP uses release materials, not debug materials.
4. Update version code/name, app icon, screenshots, privacy policy URL, support contact, and app description.
5. Complete privacy and permission disclosures. This app stores encrypted password-vault data, uses network sync, uses cryptography, and should keep permissions minimized.
6. Upload the signed HAP.
7. Use a testing or staged rollout channel first, then validate install, setup, unlock, import/export, sync, and relaunch flows.
8. Fix any review feedback about metadata, permissions, privacy policy, or package content.
9. Submit for production release after validation passes.
10. Keep release notes aligned with user-visible behavior and never list unverified or unfinished native parity work as shipped.

Official entry points:

- HarmonyOS development: https://developer.huawei.com/consumer/en/doc/harmonyos-guides/start-overview
- Stage model quick start: https://developer.huawei.com/consumer/en/doc/harmonyos-guides/start-with-ets-stage
- AppGallery Connect: https://developer.huawei.com/consumer/en/agconnect/
- AppGallery: https://developer.huawei.com/consumer/en/appgallery/

### Release Checklist

- [x] Native Stage project scaffold is in place.
- [x] Offline MVP supports setup, unlock, entry/tag management, and Preferences persistence.
- [x] `CryptoArchitectureKit` PBKDF2 + AES-GCM encryption path is wired.
- [x] TOTP and failed-unlock lockout are implemented.
- [x] HUKS hardware-key-backed biometric unlock is implemented.
- [x] WebDAV/S3 sync state machine, revisions, conflict strategy, and logs are implemented.
- [x] Item, category, and full-vault JSON export are implemented.
- [x] Item/category JSON import, preview, and conflict strategies are implemented.
- [x] Entry-reference category configuration, target selection/clear, five-state details, and repair actions are implemented.
- [x] Entry-reference UI contract tests, ArkTS compilation, and unsigned HAP build have passed.
- [x] Production bundleName/vendor metadata is configured and aligned with the Android applicationId as `life.devops.passwordmanager`.
- [x] `harmony_preflight.sh` and the HAP build script verify production metadata and a hyphen-free bundleName so example or invalid package names cannot regress.
- [x] The HAP verifier structurally validates production metadata/permissions and distinguishes unsigned from signed artifacts.
- [x] A one-command release gate now chains preflight, unsigned/signed builds, HAP verification, and optional device smoke.
- [x] Permission declaration is minimized to `ohos.permission.INTERNET` and `ohos.permission.ACCESS_BIOMETRIC`.
- [x] DevEco build, signing, device validation, permissions/privacy, and crypto compatibility regression docs exist.
- [ ] Signed HAP is generated with release signing materials.
- [ ] Signed HAP is installed on a HarmonyOS 6 device.
- [ ] Device smoke regression is completed and recorded in the result template.
- [ ] Read-only migration compatibility from historical Flutter data to HarmonyOS is validated, and legacy Flutter writeback is retired once references exist.
- [ ] Real WebDAV/S3 end-to-end sync validation is complete.
- [ ] AppGallery Connect metadata, privacy policy, permissions explanation, screenshots, and release notes are ready.
- [ ] AppGallery testing/staged channel install validation is complete.
- [ ] Production AppGallery review is approved.

### Current Verification Status

- Command-line preflight and `assembleHap` have passed, with `entry-default-unsigned.hap` recorded as the current artifact; the HAP `pack.info` / `module.json` production metadata, permissions, and unsigned state are verified by script.
- Entry-reference tests cover template type/target-category editing, unknown-type preservation, candidate filtering, five-state resolution, and raw-ID/target-secret isolation across details, summaries, search, and clipboard paths.
- Biometric unlock code has passed ArkTS compilation; the device Face/Fingerprint/HUKS token flow still requires signed-HAP installation validation.
- `hdc` was previously available in the local environment, but the device list was empty, so install and device regression could not be run.
- Signing config is still missing `HARMONY_SIGN_PROFILE` and `HARMONY_SIGN_CERTPATH`, so an installable signed HAP cannot be generated yet.
