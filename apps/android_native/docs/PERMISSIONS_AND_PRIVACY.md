# Android Native Permissions and Privacy

## 中文

该文件记录 `apps/android_native` 当前权限、数据存储和 Google Play Data safety 披露基线。它只描述原生 Android 目录。

### Manifest 权限

当前 release merged manifest 只声明三个 Android normal permissions：

- `android.permission.INTERNET`: 用于 WebDAV、NAS WebDAV 和 S3 presigned URL 手动同步。Android 不会为该 normal permission 弹出运行时授权对话框。
- `android.permission.USE_BIOMETRIC`: 用于本机生物识别解锁。应用只在用户主动启用生物识别解锁或点击生物识别解锁入口时调用系统生物识别确认。
- `android.permission.USE_FINGERPRINT`: 由 `androidx.biometric` 合入 release manifest，用于旧 Android 版本的生物识别兼容。

当前未声明：

- 外部存储读写权限。
- 相机、麦克风、定位、通讯录、日历、短信、电话、附近设备权限。
- 通知权限。

### 数据存储

- 加密 vault envelope 写入 app-private `files/vault.json`。
- 本地备份写入 app-private `files/backups/`。
- JSON 导入/导出使用 app-private `files/imports/` 和 `files/exports/`。
- 同步普通配置写入 app-private `files/sync_settings.json`，敏感同步字段在该文件中 redacted。
- 同步 secret 写入 app-private `files/sync_secrets.json`，并由 Android Keystore AES-GCM wrapping key 加密。
- `android:allowBackup="false"`，避免系统云备份复制本地加密 vault、备份和 sync secret 文件。

### Google Play Data Safety 建议

当前实现不包含账号系统、分析 SDK、广告 SDK 或第三方 telemetry。用户输入的密码库内容只保存在设备本地，除非用户主动配置 WebDAV/NAS WebDAV/S3 presigned URL 并点击同步。

建议披露：

- 数据类型：用户内容或应用活动中的密码库数据，按实际 Play Console 分类选择。
- 数据处理：默认不离开设备；启用同步时由用户配置的远端服务接收加密同步 payload。
- 加密：本地 vault 使用 PBKDF2-SHA256 和 AES-256-GCM；sync secret 使用 Android Keystore wrapping。
- 删除：用户可清除 app data；后续发布如加入账号/云端服务，需要补充远端删除流程。
- 数据共享：当前应用代码未集成第三方共享；用户自配置同步端点不应描述为开发者主动共享给第三方 SDK。

### 字段关联权限与隐私结论

- 字段关联只在现有加密 vault JSON 内增加模板元数据、稳定条目 ID 和稳定目标字段 ID，不新增 Android 权限、网络端点、SDK 或数据采集。
- Android 创建分类时即可一次性配置字段关联的目标分类和目标文本字段；模板和条目编辑 UI 只允许从匹配目标分类的可用条目中选择、更换或清空引用。详情的查看、修复和清空操作不会绕过现有密码库解锁边界。
- Android 详情、复制、搜索和日志不得暴露原始引用 ID，也不得展示、复制、索引未知字段类型或孤儿模板绑定的存储值。成功解析时只投影目标条目的名称和分类，绝不投影目标密码、Token、Secret、备注、标签或自定义字段。
- 单条/分类导出不得因为引用而隐式导出目标条目，也不得泄露目标条目的名称、用户名、密码、Token 或 Secret；只有显式包含在导出范围内的条目才能输出自身数据。
- 搜索和日志不得索引或记录被引用目标的敏感字段。该能力的数据格式见 `../../../docs/FIELD_REFERENCE_CONTRACT.md`。
- 字段关联继续存储在 app-private 加密 JSON 中；P4 不新增数据库或数据库字段，因此没有数据库迁移文件。旧快照依赖加法式 JSON 默认值兼容读取。
- P7 新增的 `targetFieldId` 是加密 vault JSON 内不透明的目标模板字段 ID。完整快照、范围导入导出和同步 payload 只保留这项元数据，不会据此隐式导出或采集目标字段值。
- P7 仅增加模型与 JSON 兼容能力，不提供 `fieldReference` UI 或解析行为，也不改变现有 `entryReference`。它不新增 Android 权限、网络端点、SDK、数据采集、数据库或数据库迁移；详细格式见 `FIELD_REFERENCE_API.md`。
- P8 领域 resolver 只在 vault 已解锁的数据边界内执行单跳解析，并只返回目标条目和目标文本字段的最小投影，绝不返回完整目标 entry/payload。P10 仅在已解锁的显式详情中展示解析值；候选列表、摘要、搜索、日志和隐式导出均不包含目标字段值或原始 ID，搜索只在解析成功时使用目标名称、分类和目标字段名称。
- P8 的复制导入重映射、分类改名传播和目标模板字段保护均为现有本地加密快照上的数据完整性处理，不新增权限、端点、SDK、采集、数据库或迁移，也不会因为字段关联隐式导出目标条目。

### 发布验证

每次 release 前运行：

```bash
./scripts/verify_release.sh
./gradlew :app:processReleaseMainManifest
./gradlew :app:connectedAndroidTest
```

配置 Play upload key 后，上传候选包应使用证书指纹门禁：

```bash
REQUIRE_SIGNED_RELEASE=true \
EXPECTED_RELEASE_CERT_SHA256=AA:BB:CC:... \
./scripts/verify_release.sh
```

然后检查：

1. merged manifest 仅包含预期 permission。
2. `android:allowBackup="false"` 仍存在。
3. `AndroidKeystoreSyncSecretStoreInstrumentedTest` 在真实 device 或 emulator 上通过。
4. Adaptive launcher icon 仍包含 foreground、round icon 和 monochrome themed icon layer。
5. Release AAB 使用预期 Play upload certificate SHA-256 指纹。
6. Play Console Data safety 与当前功能一致。

## English

This file records the current permissions, data storage, and Google Play Data safety disclosure baseline for `apps/android_native`. It only describes the native Android directory.

### Manifest Permissions

The release merged manifest declares three Android normal permissions:

- `android.permission.INTERNET`: used for WebDAV, NAS WebDAV, and S3 presigned URL manual sync. Android does not show a runtime prompt for this normal permission.
- `android.permission.USE_BIOMETRIC`: used for local biometric unlock. The app invokes system biometric confirmation only when the user enables biometric unlock or taps the biometric unlock entry point.
- `android.permission.USE_FINGERPRINT`: merged from `androidx.biometric` for biometric compatibility on older Android versions.

The current manifest does not declare:

- External storage read/write permissions.
- Camera, microphone, location, contacts, calendar, SMS, phone, or nearby-device permissions.
- Notification permission.

### Data Storage

- The encrypted vault envelope is stored in app-private `files/vault.json`.
- Local backups are stored in app-private `files/backups/`.
- JSON import/export uses app-private `files/imports/` and `files/exports/`.
- Plain sync settings are stored in app-private `files/sync_settings.json`, with sensitive sync fields redacted.
- Sync secrets are stored in app-private `files/sync_secrets.json`, encrypted by an Android Keystore AES-GCM wrapping key.
- `android:allowBackup="false"` prevents system cloud backup from copying the local encrypted vault, backups, and sync secret files.

### Entry-Reference Permissions And Privacy

- Entry references add only template metadata and stable entry IDs inside the existing encrypted vault JSON. They add no Android permission, network endpoint, SDK, or data collection.
- Android template and entry editors allow a reference to be selected, replaced, or cleared only from available entries matching the target-category constraint. Detail view, repair, and clear actions remain behind the existing unlocked-vault boundary.
- Android details, copy actions, search, and logs must not expose raw reference IDs or display, copy, or index stored values belonging to unknown field types or orphaned template bindings. A resolved reference projects only the target label and category, never its password, token, secret, notes, tags, or custom fields.
- Item/category export must not include a referenced target implicitly or disclose its label, username, password, token, or secret. Only entries explicitly selected by the export scope may output their own data.
- Search and logs must not index or record sensitive fields from referenced targets. See `../../../docs/FIELD_REFERENCE_CONTRACT.md` for the data contract.
- Entry references remain in app-private encrypted JSON. P4 adds no database or database column, so there is no database migration file; additive JSON defaults keep older snapshots readable.
- The P7 `targetFieldId` is an opaque target template-field ID inside the encrypted vault JSON. Full snapshots, scoped import/export, and sync payloads preserve only this metadata; it does not implicitly export or collect a target field value.
- P7 adds model and JSON compatibility only. It provides no `fieldReference` UI or resolution behavior and does not change existing `entryReference` semantics. It adds no Android permission, network endpoint, SDK, data collection, database, or database migration. See `FIELD_REFERENCE_API.md` for the detailed format.
- The P8 domain resolver performs one-hop resolution only inside the unlocked-vault boundary and returns no more than minimal target-entry and target-text-field projections, never a complete target entry or payload. P10 displays a resolved value only in the unlocked explicit detail view; candidates, summaries, search, logs, and implicit exports exclude the value and raw IDs. Successful search projection uses only the target label, category, and target field name.
- P8 copy-import remapping, category-rename propagation, and target-template protection are data-integrity operations on the existing locally encrypted snapshot. They add no permission, endpoint, SDK, collection, database, or migration, and a field reference never causes an implicit target-entry export.

### Google Play Data Safety Guidance

The current implementation has no account system, analytics SDK, advertising SDK, or third-party telemetry. Password-vault content entered by the user stays on device unless the user explicitly configures WebDAV/NAS WebDAV/S3 presigned URL sync and taps sync.

Recommended disclosure:

- Data type: password-vault data under user content or app activity, depending on the Play Console taxonomy available at submission time.
- Data handling: does not leave the device by default; when sync is enabled, the user-configured remote service receives encrypted sync payloads.
- Encryption: the local vault uses PBKDF2-SHA256 and AES-256-GCM; sync secrets use Android Keystore wrapping.
- Deletion: users can clear app data; if a future release adds accounts or first-party cloud services, add the remote deletion flow.
- Data sharing: the current app code does not integrate third-party sharing; user-configured sync endpoints should not be described as developer-initiated sharing with a third-party SDK.

### Release Verification

Before each release, run:

```bash
./scripts/verify_release.sh
./gradlew :app:processReleaseMainManifest
./gradlew :app:connectedAndroidTest
```

After configuring the Play upload key, gate upload candidates with the certificate fingerprint:

```bash
REQUIRE_SIGNED_RELEASE=true \
EXPECTED_RELEASE_CERT_SHA256=AA:BB:CC:... \
./scripts/verify_release.sh
```

Then check:

1. The merged manifest contains only expected permissions.
2. `android:allowBackup="false"` is still present.
3. `AndroidKeystoreSyncSecretStoreInstrumentedTest` passes on a real device or emulator.
4. The adaptive launcher icon still includes foreground, round icon, and monochrome themed icon layers.
5. The Release AAB uses the expected Play upload certificate SHA-256 fingerprint.
6. Play Console Data safety remains aligned with current functionality.
