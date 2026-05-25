# Android Native Permissions and Privacy

## 中文

该文件记录 `apps/android_native` 当前权限、数据存储和 Google Play Data safety 披露基线。它只描述原生 Android 目录，不覆盖或修改 `apps/flutter_app`。

### Manifest 权限

当前 manifest 只声明一个 Android normal permission：

- `android.permission.INTERNET`: 用于 WebDAV、NAS WebDAV 和 S3 presigned URL 手动同步。Android 不会为该 normal permission 弹出运行时授权对话框。

当前未声明：

- 外部存储读写权限。
- 相机、麦克风、定位、通讯录、日历、短信、电话、附近设备权限。
- 生物识别权限。
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

This file records the current permissions, data storage, and Google Play Data safety disclosure baseline for `apps/android_native`. It only describes the native Android directory and does not cover or modify `apps/flutter_app`.

### Manifest Permissions

The current manifest declares one Android normal permission:

- `android.permission.INTERNET`: used for WebDAV, NAS WebDAV, and S3 presigned URL manual sync. Android does not show a runtime prompt for this normal permission.

The current manifest does not declare:

- External storage read/write permissions.
- Camera, microphone, location, contacts, calendar, SMS, phone, or nearby-device permissions.
- Biometric permissions.
- Notification permission.

### Data Storage

- The encrypted vault envelope is stored in app-private `files/vault.json`.
- Local backups are stored in app-private `files/backups/`.
- JSON import/export uses app-private `files/imports/` and `files/exports/`.
- Plain sync settings are stored in app-private `files/sync_settings.json`, with sensitive sync fields redacted.
- Sync secrets are stored in app-private `files/sync_secrets.json`, encrypted by an Android Keystore AES-GCM wrapping key.
- `android:allowBackup="false"` prevents system cloud backup from copying the local encrypted vault, backups, and sync secret files.

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
