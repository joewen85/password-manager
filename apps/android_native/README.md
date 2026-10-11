# Password Manager Android Native

## 中文

该目录包含 Android 原生应用，用于逐步补齐 Android 端原生能力。

### 范围

- 使用 Kotlin 编写原生 Android 应用。
- 首个原生等价切片：初始化/解锁保险库、锁定保险库、条目列表、搜索、新增/编辑/删除 credential/server/service 条目、分类和标签字段、基于 TOTP 的二次验证解锁、手动同步入口、本地加密备份、完整快照 JSON 导入/导出。
- 折叠屏和大屏适配是 Android baseline 的一部分：紧凑宽度使用单栏列表并通过 dialog 展示详情，扩展宽度使用双栏列表/详情布局；垂直 separating fold 使用左右分区，水平 separating fold/tabletop 使用上下分区，并在折痕处插入分隔带，避免列表/详情内容跨越折叠区域。Manifest 声明 activity 可调整大小并支持 large/xlarge screens，应用监听 Jetpack WindowManager `FoldingFeature` 更新，因此在达到普通宽度阈值前，separating fold 也可以驱动适配布局。
- 数据模型对齐现有共享契约：`credential`、`server`、`service`、PBKDF 元数据记录、AES-GCM payload 记录形状、软删除字段、版本映射和 `updatedBy`。
- 已实现本地加密文件持久化。应用会将加密后的保险库 envelope 写入 app-private storage，并使用 PBKDF2-SHA256 验证主密码、使用 AES-256-GCM 加密 payload。
- 已准备 Android Keystore key creation 作为设备能力检查，但当前保险库加密仍直接使用主密码派生的 AES key，以保持持久化格式可移植并兼容现有 crypto 契约。
- PBKDF2 默认参数与 Dart package 契约对齐：新建 Android 原生保险库使用 600000 次迭代。
- JVM 单元测试覆盖 PBKDF2 verifier 行为、AES-GCM 往返、TOTP 生成/验证、credential/server/service/tombstone payload 的 JSON 快照往返、PBKDF2/AES-GCM Dart fixture 兼容性，以及 compact/expanded/fold-separating 布局策略。
- Service 条目的 service accounts 在 Android 原生编辑表单中使用 `username:password:note; ...` 紧凑格式录入，并在详情页显示账号、遮蔽密码。
- 折叠/紧凑态操作区已提供分类和标签入口：分类/标签仍来自条目字段，入口会预填新建条目的 category 或 tags，不引入新的数据模型。
- UI 文案已拆分为英文默认资源和中文 `values-zh` 资源，条目类型、同步 provider、冲突策略等用户可见枚举也走资源化文本；系统语言为中文时显示中文。颜色已拆分为 light/night 资源，默认跟随系统深色/浅色模式。
- 条目/分类级 JSON 导入导出已实现，导入时支持 Keep Copy、Overwrite、Skip 冲突策略。
- 字段关联已完成 Android UI 垂直切片：创建分类时即可为新字段选择 `text` 或 `fieldReference`，并在首次保存前同时选择目标分类和目标文本字段；同分类可关联本次草稿中的其他文本字段，无需先创建文本字段再进入模板编辑。旧 `entryReference` 模板定义只读保留，已有条目值仍可选择、更换和清空。`fieldReference` 详情覆盖九态，配置错误进入分类字段修复，条目错误进入目标重选；解析值只在已解锁的显式详情中展示。候选列表、摘要、搜索和日志不暴露原始 ID 或目标字段值；同批复制导入、同步和生命周期保护继续使用统一契约。标签职责不变，格式与上线顺序见 `../../docs/FIELD_REFERENCE_CONTRACT.md`。
- 字段关联仍存储在现有加密 vault JSON 的 `categoryTemplates` 与 `customFields` 中，不新增数据库或数据库字段，因此不需要数据库迁移文件；旧快照通过加法式 JSON 默认值继续读取。
- P7 已加入字段级关联的数据契约：`FieldTemplate.targetFieldId` 保存不透明的目标模板字段 ID，缺失时默认读取为空字符串。完整快照、单条/分类范围导入导出和同步 payload 均会无损保留该字段，未知 `valueType` 也不会丢弃它。P7 阶段仅提供模型与 JSON 兼容能力，未开放 `fieldReference` 的 Android UI 或解析行为，也未改变既有 `entryReference` 语义；格式见 `docs/FIELD_REFERENCE_API.md`。
- P8 已完成 `fieldReference` Android 领域层：仅精确识别该类型，并按 `EMPTY`、`INVALID_CONFIGURATION`、`MISSING`、`DELETED`、`CATEGORY_MISMATCH`、`TARGET_FIELD_MISSING`、`TARGET_FIELD_UNSUPPORTED`、`TARGET_FIELD_EMPTY`、`RESOLVED` 的优先级执行单跳解析。解析结果只包含目标条目和目标文本字段的最小投影，不返回完整 entry/payload；搜索仅在 `RESOLVED` 时加入目标条目名称/分类和目标字段名称，不加入目标字段值、原始 ID 或目标秘密。复制导入会重映射来源值而保留 `targetFieldId`，分类改名会传播目标分类，被引用的目标文本字段允许改名但禁止删除或改型。P8 阶段本身未开放 UI，后续由 P10 接入。
- P10 已开放 `fieldReference` Android UI：创建分类时即可在首次保存前选择字段类型、目标分类和目标文本字段，分类模板保存稳定 `targetFieldId`，支持同分类关联本次草稿中的其他文本字段并拒绝直接自引用；条目编辑、候选筛选、九态详情、查看目标、清除和按错误类型修复均已接入。新模板不再创建旧 `entryReference`，但旧定义和值保持无损兼容。
- 本地备份支持恢复最新加密备份，并自动保留最近 5 个备份文件。
- 同步合并数据层已对齐 Flutter 的 version-vector 规则：本地/远端支配、并发冲突、delete-vs-update tombstone、keep-both conflict copy 均有 JVM 测试覆盖。
- 远端同步 transport 层已对齐 Flutter 的 WebDAV 和 S3 presigned URL 行为：路径归一化、Basic Auth、JSON PUT、404/204 空远端、timeout/error 状态映射均有 JVM 测试覆盖。
- 同步设置模型已对齐 Flutter 字段契约：provider type、WebDAV/NAS WebDAV、S3 presigned URL、auto-sync、conflict strategy、sync master key、device id、revision、status 和 logs。原生 client factory 已可根据设置选择 WebDAV、NAS WebDAV 或 S3 presigned URL client。
- 同步引擎数据层已实现下载远端 payload、合并本地/远端快照、应用远端支配结果、上传新 revision、更新 sync revision/status/logs 的流程，并覆盖缺失远端、远端支配和并发冲突上传场景。
- 已新增 Keystore-wrapped sync secret file store，并支持将 `webdavPassword`、presigned download/upload URL 从普通 `SyncSettings` 中 redacted 后再落盘；JVM 测试使用 fake cipher 验证不会持久化明文 secret，并覆盖普通配置文件无明文 secret、`VaultStore` 重新加载同步设置。
- 已新增 Android instrumented test：`AndroidKeystoreSyncSecretStoreInstrumentedTest`，用于在真实 device/emulator 上验证 Android Keystore wrapping 后的 sync secret 文件不包含明文 secret。
- 同步设置 UI 已接入 `VaultStore` 和 Keystore-wrapped secret store；provider 选择会只展示对应的 WebDAV/NAS WebDAV 或 S3 presigned URL 字段，避免在未配置 provider 时暴露无关输入。手动同步入口已连接 `SyncClientFactory` 与 `VaultSyncEngine`，可上传本地 payload、应用合并结果并持久化 revision/status/logs。
- Release merged manifest 只声明 `INTERNET`、`USE_BIOMETRIC` 与 `USE_FINGERPRINT` normal permissions，并保持 `android:allowBackup="false"`；权限和 Google Play Data safety 披露基线见 `docs/PERMISSIONS_AND_PRIVACY.md`。
- Adaptive launcher icon 已包含 foreground、background、round icon 和 Android 13+ themed icon 所需的 monochrome layer。
- Debug APK 已在 `Medium_Phone_API_36.1` AVD（Android 16 / API 36）上完成安装和启动冒烟验证；launcher activity 解析为 `.MainActivity`，首屏 UI tree 显示 `Initialize Vault`、主密码/确认密码输入框和 `Create Vault`。
- Debug APK、未签名 release AAB、androidTest APK 构建、release manifest 处理、release verification 脚本、JVM 测试和 Keystore-backed key wrapping instrumentation test 已通过。本次设备级验证使用 `Medium_Phone_API_36.1` AVD（Android 16 / API 36）。生产发布前仍需完成 upload key 签名校验、真实 WebDAV/S3 端到端服务验证和生产 UI polish。
- 字段关联 UI 已在 `Medium_Phone_API_36.1` AVD 的新会话中完成设备复验：compact 布局覆盖模板配置与已存值门禁、选择/更换/清空、目标名称搜索、`resolved`/`empty`/`deleted`/`categoryMismatch` 详情、查看目标和修复入口；expanded 布局覆盖真实 `resolved` 与 `categoryMismatch` 双栏详情，按钮、文字和弹层无重叠。compact/expanded 基础布局脚本均通过，目标 app crash buffer 为空。`missing` 状态由 JVM 回归测试覆盖；完整平板/折叠屏姿态与发布设备矩阵仍需按下方清单执行。

### 环境要求

- 支持 Android Gradle Plugin 8.11.1 的 Android Studio。
- JDK 21 或更高版本。
- Android SDK Platform 36。
- API 26 或更高版本的 Android emulator 或 device。

本机校验使用 JDK 21，路径为 `/Users/joe/Tools/jdk21/zulu-21.jdk/Contents/Home`。`scripts/verify_release.sh` 会优先使用该 JDK，并在当前 Java 版本低于 21 时失败。

### 开发

在当前目录运行：

```bash
./gradlew :app:assembleDebug
```

如果复制 checkout 后 wrapper 执行位丢失，恢复一次即可：

```bash
chmod +x ./gradlew
```

安装到已连接设备：

```bash
./gradlew :app:installDebug
```

运行单元测试：

```bash
./gradlew test
```

添加 Android instrumented tests 后运行：

```bash
./gradlew connectedAndroidTest
```

仅编译 instrumented test APK：

```bash
./gradlew :app:assembleAndroidTest
```

运行本地 release gate：

```bash
./scripts/verify_release.sh
```

该脚本会使用 JDK 21+、禁用 Gradle daemon、启用 Kotlin in-process 编译，运行 JVM 测试、Debug APK 构建、androidTest APK 构建、Release AAB 构建和 release manifest 处理，然后检查 Android `namespace` / `applicationId` 是无横杠点分发布标识、merged manifest 权限、`allowBackup=false`、launcher activity、adaptive icon / round icon / monochrome themed icon 资源。未配置 Play upload key 时，脚本会明确报告 AAB 为 unsigned。配置 upload key 后，可设置 `EXPECTED_RELEASE_CERT_SHA256` 校验签名证书指纹；设置 `REQUIRE_SIGNED_RELEASE=true` 可让 unsigned AAB 直接失败。

运行设备启动冒烟验证：

```bash
./scripts/device_launch_smoke.sh
```

该脚本要求已连接一个 adb device/emulator，或通过 `ANDROID_SERIAL=<serial>` 指定目标设备。它会安装 Debug APK、解析 launcher activity、默认清空 app 数据、启动应用、校验初始化保险库首屏文本，保存 `build/device-smoke/ui.xml` 和 `build/device-smoke/launch.png`，并确认 crash buffer 为空。若需要保留当前 app 数据，可设置 `RESET_APP_DATA=false`。

运行设备布局冒烟验证：

```bash
./scripts/device_layout_smoke.sh
```

该脚本要求已连接一个 adb device/emulator，或通过 `ANDROID_SERIAL=<serial>` 指定目标设备。它会安装 Debug APK，临时切换 `wm size`/`wm density` 到 compact phone 和 expanded tablet 两组窗口，清空 app 数据并创建临时 vault，然后用 UI tree 校验 compact 模式下 `New`、`Category`、`Tag`、`Sync`、`Backups`、`Search vault` 入口可见且不渲染详情栏，expanded 模式渲染 `Select an entry` 详情占位，保存 `build/device-layout-smoke/` 下的 UI tree、截图和 crash buffer，并确认目标 app 没有写入 crash buffer；脚本退出时会恢复显示设置。

字段关联 UI 需要在 compact 和 expanded 两种布局中分别完成以下设备验证；基础布局脚本不能替代这些功能步骤：

1. 创建目标分类和来源分类，在目标分类新增文本字段，在来源分类新增字段关联，并同时选择目标分类与目标文本字段；另验证同分类关联其他文本字段可保存、直接自引用不可保存。
2. 新建目标条目和来源条目，在来源条目中选择目标记录，再依次验证更换与清空引用。
3. 在详情中验证已解析引用显示目标名称、目标字段名和解析值，点击“查看”可打开目标条目；候选、摘要和搜索中不得出现解析值或原始引用 ID。
4. 构造全部九态，验证条目缺失/删除/分类不匹配进入目标重选，配置无效/目标字段缺失/目标字段不支持进入分类字段编辑，目标字段空值仍可查看或更换目标。
5. 导入包含未知 `valueType` 或孤儿 `templateFieldId` 的兼容数据，确认其原始存储值不会显示、复制或进入搜索结果。
6. 在 compact 模式确认编辑器和详情 dialog 可滚动、按钮可点击、文字不被裁切；在 expanded 模式确认列表/详情双栏和弹层不会越过窗口或折痕边界。
7. 保存每种布局的截图、UI tree 和目标 app crash buffer，并在设备型号、API 版本和 posture 记录齐全后再勾选发布检查项。

当前没有连接的 Android device/emulator，因此本轮文档更新不宣称上述 P4 设备验证已经通过。

### 本地加密校验

修改持久化或加密代码后，使用以下流程校验：

1. 在 emulator 或 device 上构建并安装 debug app。
2. 使用主密码初始化保险库。
3. 至少新增一个 credential、一个 server 和一个 service 条目。
4. Force-stop 并重新打开应用。
5. 验证错误密码无法解锁，正确密码可以恢复全部条目。
6. 在 Settings 中保存 Base32 TOTP shared secret，启用 2FA，锁定保险库，并验证缺失/错误验证码会被拒绝，当前 authenticator code 可以通过。
7. 执行手动备份，确认 app-private `files/backups/vault-*.json` 已创建，且文件包含加密 envelope 而非明文保险库字段。
8. 执行 JSON 导出，确认 app-private `files/exports/vault-export-*.json` 包含预期的完整快照 JSON。
9. 将快照 JSON 文件复制到 app-private `files/imports/`，执行 JSON 导入，并确认 entries/categories/tags/security settings 被导入快照替换。
10. 通过 Android Studio Device Explorer 或 debug build 的 `run-as` 检查 app-private `files/vault.json`，确认文件中不存在明文 label、username、password、token、server name 或 service name。
11. 在 compact 和 expanded foldable posture 中重复同一流程。

### 折叠屏和大屏校验

每次 Android 原生发布前，至少使用一个折叠屏 emulator profile 和一个 tablet profile：

1. 创建 Android Studio emulator，例如 Pixel Fold 或 Pixel 9 Pro Fold，并创建一个 medium tablet profile。
2. 安装 debug build：

   ```bash
   ./gradlew :app:installDebug
   ```

3. 先运行可重复布局冒烟脚本，验证普通 emulator 在 compact/expanded 宽度阈值两侧的基础布局切换：

   ```bash
   ./scripts/device_layout_smoke.sh
   ```

4. 校验 compact posture：折叠/窄宽度先展示列表，并通过 dialog 打开条目详情。
5. 校验 expanded posture：展开/宽屏时并排展示列表和详情栏。
6. 校验平铺垂直 separating fold posture：应用使用双栏布局，并将列表/详情内容保持在 fold 两侧。
7. 校验水平 separating fold/tabletop posture：应用使用上下分区，列表和详情不会跨越折叠区域。
8. 旋转设备并重复新增/编辑/删除/搜索流程，确认搜索关键字和选中详情在折叠/展开重建后仍保留。
9. 验证紧凑/折叠态下分类和标签入口可见，且新建条目会预填对应 category 或 tag。
10. 在 compact 和 expanded posture 中重复字段关联的首次创建配置、选择、更换、清空、九态详情、查看和修复流程，确认原始 ID、未知类型值和孤儿绑定值不会显示、复制或被搜索命中。
11. 验证文字可读、详情操作可见，并且 hinge 或窗口边界附近没有控件被裁切。
12. 在 Android multi-window 模式下运行应用，并跨 compact/expanded 阈值调整窗口大小。

### 权限、备份和隐私披露

当前 manifest 最小权限基线：

- `android.permission.INTERNET`: normal permission，用于 WebDAV、NAS WebDAV 和 S3 presigned URL 手动同步。
- `android.permission.USE_BIOMETRIC`: normal permission，用于本机生物识别解锁。
- `android.permission.USE_FINGERPRINT`: 由 `androidx.biometric` 合入 release manifest，用于旧 Android 版本的生物识别兼容。
- 无外部存储、相机、麦克风、定位、通讯录、日历、短信、电话、附近设备或通知权限。
- `android:allowBackup="false"`，避免系统云备份复制本地加密 vault、备份和 sync secret 文件。

完整披露和 Play Data safety 建议见：

```text
docs/PERMISSIONS_AND_PRIVACY.md
```

### 发布构建

1. 创建或获取 Play upload keystore。
2. 将签名凭据存放在 git 之外，例如 `~/.gradle/gradle.properties` 或 CI secret store。`app/build.gradle.kts` 已支持以下可选属性：

   ```properties
   PASSWORD_MANAGER_RELEASE_STORE_FILE=/absolute/path/to/upload-keystore.jks
   PASSWORD_MANAGER_RELEASE_STORE_PASSWORD=...
   PASSWORD_MANAGER_RELEASE_KEY_ALIAS=...
   PASSWORD_MANAGER_RELEASE_KEY_PASSWORD=...
   ```

   四个属性都存在时，release build 会使用 upload key 签名；缺少任一属性时，release bundle / APK 仍可构建为未签名 artifact，用于 CI 编译验证。

3. 通过 Gradle property 传版本号。`VERSION_NAME` 是对外版本号，`VERSION_CODE` 是正整数构建号，必须每次发版递增；不传时默认使用 `1.0.0` 和 `1`。
4. 构建 Android App Bundle：

   ```bash
   ./gradlew :app:bundleRelease -PVERSION_NAME=1.2.3 -PVERSION_CODE=45
   ```

5. 仅在直接分发或内部 QA 需要 APK 时构建 APK：

   ```bash
   ./gradlew :app:assembleRelease -PVERSION_NAME=1.2.3 -PVERSION_CODE=45
   ```

   如果只传 `VERSION_NAME` / `VERSION_CODE`，但没有提供上面的四个 `PASSWORD_MANAGER_RELEASE_*` 签名属性，APK 会生成在：

   ```text
   app/build/outputs/apk/release/app-release-unsigned.apk
   ```

   `app-release-unsigned.apk` 是未签名包，不能作为正常 Android 安装包分发或安装。提供 release keystore 后再构建，APK 会生成在：

   ```text
   app/build/outputs/apk/release/app-release.apk
   ```

   AAB 产物固定生成在：

   ```text
   app/build/outputs/bundle/release/app-release.aab
   ```

   正式签名 APK 构建示例：

   ```bash
   ./gradlew :app:assembleRelease \
     -PVERSION_NAME=1.0.13 \
     -PVERSION_CODE=14 \
     -PPASSWORD_MANAGER_RELEASE_STORE_FILE=/absolute/path/to/upload-keystore.jks \
     -PPASSWORD_MANAGER_RELEASE_STORE_PASSWORD='...' \
     -PPASSWORD_MANAGER_RELEASE_KEY_ALIAS='...' \
     -PPASSWORD_MANAGER_RELEASE_KEY_PASSWORD='...'
   ```

   本机临时测试安装可以使用 Android debug keystore 生成可安装 APK，但该包只适合本机/QA 验证，不能用于正式发布或上传商店：

   ```bash
   ./gradlew :app:assembleRelease \
     -PVERSION_NAME=1.0.13 \
     -PVERSION_CODE=14 \
     -PPASSWORD_MANAGER_RELEASE_STORE_FILE="$HOME/.android/debug.keystore" \
     -PPASSWORD_MANAGER_RELEASE_STORE_PASSWORD=android \
     -PPASSWORD_MANAGER_RELEASE_KEY_ALIAS=androiddebugkey \
     -PPASSWORD_MANAGER_RELEASE_KEY_PASSWORD=android
   ```

   也可以把版本号写入 CI secret 或本机 `~/.gradle/gradle.properties`：

   ```properties
   VERSION_NAME=1.2.3
   VERSION_CODE=45
   ```

6. 提供签名属性后，验证 bundle：

   ```bash
   jarsigner -verify -verbose -certs app/build/outputs/bundle/release/app-release.aab
   ```

7. 每次准备上传前运行本地 release gate。配置 upload key 后，建议同时传入 Play upload certificate SHA-256 指纹：

   ```bash
   REQUIRE_SIGNED_RELEASE=true \
   EXPECTED_RELEASE_CERT_SHA256=AA:BB:CC:... \
   ./scripts/verify_release.sh
   ```

### Google Play 上架

1. 在 Google Play Console 创建应用。
2. 配置 package name、app category、contact details、content rating、target audience、privacy policy URL 和 Data safety form。
3. 完成 encryption/export compliance 回答。该应用会保存加密的密码保险库数据并使用 cryptography。
4. 先将签名 `.aab` 上传到 internal testing。
5. 在干净设备 profile 上通过 Play 测试安装。
6. 验证后依次推广到 closed、open 和 production tracks。
7. Release notes 只描述用户可见变更，不要把未完成的原生等价工作写成已发布能力。

### 发布检查清单

- [x] 原生存储使用本地 vault envelope，通过 AES-256-GCM 加密。
- [x] 主密钥 verifier 使用现有默认迭代次数的 PBKDF2-SHA256。
- [x] Debug APK 构建通过。
- [x] Debug APK 已在 `Medium_Phone_API_36.1` AVD（Android 16 / API 36）安装并启动到初始化保险库首屏。
- [x] 设备启动冒烟脚本已提供，可重复验证 launcher activity、初始化保险库首屏 UI tree、截图和 crash buffer。
- [x] 设备布局冒烟脚本已提供，可重复验证 compact/expanded 宽度阈值两侧的基础布局切换、截图和目标 app crash buffer。
- [x] Release AAB 构建配置支持可选 Play upload key 签名。
- [x] 未提供签名属性时，release AAB 可作为未签名 artifact 构建用于 CI 编译验证。
- [x] 本地 release verification 脚本会使用 JDK 21+ 串联测试、构建、无横杠 `namespace` / `applicationId`、manifest 权限、`allowBackup=false`、launcher activity、launcher icon 资源检查，并可用 `EXPECTED_RELEASE_CERT_SHA256` 校验 Play upload certificate 指纹。
- [x] Instrumented test APK 构建通过，包含 Android Keystore sync secret wrapping 设备验证用例。
- [x] Release manifest 处理通过，并声明 `INTERNET`、`USE_BIOMETRIC` 与 `USE_FINGERPRINT` normal permissions 以支持真实远端同步和本机生物识别解锁。
- [x] Adaptive launcher icon 包含 foreground、background、round icon 和 Android 13+ themed icon 的 monochrome layer。
- [x] JVM 测试覆盖 crypto 往返、TOTP 验证、credential/server/service/tombstone payload 的 JSON 快照往返、service account 表单解析、Dart fixture 兼容性，以及 fold-aware layout policy。
- [x] TOTP 解锁验证与 Flutter auth package 默认参数一致：SHA1、30 秒周期、6 位数字、+/-1 时间窗口。
- [x] 手动备份会创建带时间戳的 app-private 加密保险库 envelope 副本。
- [x] 本地备份支持恢复最新加密备份，并保留最近 5 个备份。
- [x] 完整快照 JSON 导入/导出可通过 app-private `exports/` 和 `imports/` 目录使用。
- [x] 条目/分类 JSON 导入导出支持 Keep Copy、Overwrite、Skip 冲突策略。
- [x] Android 新建分类时可直接配置文本/字段关联类型、目标分类和目标文本字段，条目编辑支持选择、更换与清空引用，详情支持九态、查看、修复和清空。
- [x] Android 详情、复制和搜索不暴露原始引用 ID、未知类型值或孤儿绑定值；搜索只投影成功解析目标的名称和分类。
- [x] P4 字段关联已在新的 compact/expanded AVD 会话中验证并保留截图、UI tree 与 crash buffer；compact 覆盖主要编辑和四种可直接构造的详情状态，expanded 覆盖真实 resolved/categoryMismatch 双栏详情，missing 由 JVM 回归测试覆盖。
- [x] P7 字段级关联数据契约会在完整快照、单条/分类范围导入导出和同步 payload 中保留 `targetFieldId`，旧数据默认空值且未知字段类型往返无损。
- [x] P7 先完成无损数据契约且未开放 UI；P8 增加领域 resolver，P10 再开放 UI，现有 `entryReference` 行为保持兼容。
- [x] P8 Android 领域 resolver 覆盖全部九种状态、严格单跳/自引用保护和最小安全投影。
- [x] P8 搜索仅投影已解析目标的名称、分类和目标字段名称，不索引目标字段值、原始 ID、payload secrets 或完整目标条目。
- [x] P8 复制导入重映射字段关联的目标条目 ID，分类改名传播目标分类，同步保持元数据和值；被引用的目标文本字段可改名但不可删除或改型。
- [x] P10 Android 分类模板、条目编辑和显式详情已接入 `fieldReference` 九态 UI；旧 `entryReference` 模板只读、已有值可继续编辑，解析值不进入候选、摘要、搜索或日志。
- [x] 同步合并数据层覆盖 version-vector 支配、并发冲突、delete-vs-update tombstone 和 keep-both conflict copy。
- [x] WebDAV 和 S3 presigned URL 同步 transport 层覆盖路径归一化、Basic Auth、JSON PUT 和网络错误映射。
- [x] 同步设置模型和 provider client factory 覆盖 Flutter 字段契约、默认值和未知值兼容。
- [x] 同步引擎数据层覆盖缺失远端、远端支配、并发冲突合并上传和 revision/status/log 更新。
- [x] Keystore-wrapped sync secret file store 已实现；同步敏感字段可从普通设置中 redacted 后保存，JVM 测试确认 fake cipher 文件不含明文 secret。
- [x] Android Keystore-backed key wrapping instrumentation test 已在 `Medium_Phone_API_36.1` AVD（Android 16 / API 36）上执行并通过。
- [x] 同步设置 UI 已接入 Keystore-wrapped secret store，会隐藏无关 provider 字段，且普通配置文件不持久化明文同步 secrets。
- [x] 手动同步入口已连接 provider client factory、同步引擎、加密保险库持久化和同步设置持久化。
- [ ] 真实 WebDAV/S3 端到端服务验证完成。
- [x] 代表性 Dart-generated vault payload fixture 的兼容性测试通过。
- [x] Network、storage、backup 和 biometric permissions 已最小化并完成披露。
- [ ] Release AAB 已由 upload key 签名，通过 internal track 安装，并在 API 26、当前稳定 Android、一个 tablet profile、一个 foldable profile 的 compact 和 expanded postures 中测试。

---

## English

This directory contains the native Android application target, used to build Android-native parity incrementally.

### Scope

- Native Android application written in Kotlin.
- First native parity slice: initialize/unlock vault, lock vault, list entries, search, add/edit/delete credential/server/service entries, category and tag fields, TOTP-based 2FA unlock verification, manual sync entry point, local encrypted backup creation, and full snapshot JSON import/export.
- Foldable and large-screen adaptation is part of the baseline Android target: compact widths use a single-pane list with dialog details, expanded widths use a two-pane list/detail layout, vertical separating folds keep list/detail on opposite sides, and horizontal separating folds/tabletop posture use top/bottom regions with an explicit fold gap so primary content does not cross the fold. The manifest declares the activity as resizable and supports large/xlarge screens, and the app listens to Jetpack WindowManager `FoldingFeature` updates so a separating fold can drive the adaptive layout before the normal width threshold is reached.
- Data model mirrors the current shared contract: `credential`, `server`, `service`, PBKDF metadata records, AES-GCM payload record shape, soft-delete fields, version map, and `updatedBy`.
- Local encrypted file persistence is implemented. The app writes an encrypted vault envelope to app-private storage using PBKDF2-SHA256 master password verification and AES-256-GCM payload encryption.
- Android Keystore key creation is prepared as a device capability check, but vault encryption currently uses the master-password-derived AES key directly so the persisted format remains portable and compatible with the existing crypto contract.
- PBKDF2 defaults are aligned with the Dart package contract: 600000 iterations for new native Android vaults.
- JVM unit tests cover PBKDF2 verifier behavior, AES-GCM round trip, TOTP generation/verification, JSON snapshot round trip for credential/server/service/tombstone payloads, PBKDF2/AES-GCM Dart fixture compatibility, and the compact/expanded/fold-separating layout policy.
- Service accounts on service entries are edited in the Android native form with the compact `username:password:note; ...` format and shown in details with passwords masked.
- Item/category scoped JSON import/export is implemented with Keep Copy, Overwrite, and Skip conflict strategies.
- Legacy entry references retain their complete Android UI slice for existing definitions and values. New category fields no longer create `entryReference`; entry editing can still select, replace, or clear one matching legacy target. Details render the legacy `empty`, `resolved`, `missing`, `deleted`, and `categoryMismatch` states, with a view action for a valid target and repair or clear actions for unavailable targets. Search adds only a successfully resolved target label and category, never the raw reference ID or target secrets; details, copy actions, and search also suppress raw IDs and stored values belonging to unknown field types or orphaned bindings. Batch copy import assigns destination IDs before rewriting internal references, keeps IDs for targets not included, and sync comparison/conflict copies retain reference fields and `templateFieldId`. Tags remain unchanged. See `../../docs/FIELD_REFERENCE_CONTRACT.md` for the format and rollout order.
- Entry references remain inside the existing encrypted vault JSON under `categoryTemplates` and `customFields`. P4 adds no database or database column, so no database migration file is required; additive JSON defaults remain the migration path for older snapshots.
- P7 adds the field-level reference data contract. `FieldTemplate.targetFieldId` stores an opaque target template-field ID and defaults to an empty string when absent. Full snapshots, item/category scoped import/export, and sync payloads preserve it losslessly, including when `valueType` is unknown. This phase provides model and JSON compatibility only: Android UI and resolvers do not create or execute `fieldReference`, and existing `entryReference` semantics remain unchanged. See `docs/FIELD_REFERENCE_API.md` for the format.
- P8 completes the Android domain layer for `fieldReference`. Only the exact type is recognized, with one-hop resolution precedence `EMPTY`, `INVALID_CONFIGURATION`, `MISSING`, `DELETED`, `CATEGORY_MISMATCH`, `TARGET_FIELD_MISSING`, `TARGET_FIELD_UNSUPPORTED`, `TARGET_FIELD_EMPTY`, then `RESOLVED`. Results contain only minimal target-entry and target-text-field projections, never the complete entry or payload. Search adds the resolved target label/category and target field name only; it excludes the target field value, raw IDs, and target secrets. Copy import remaps the source value while retaining `targetFieldId`, category rename propagates the target category, and a referenced target text field may be renamed but not deleted or retyped. P8 itself did not enable UI; P10 adds it later.
- P10 enables the Android `fieldReference` UI. Initial category creation selects the field type, target category, and target text field before the first save, with no temporary text-field step. Category templates persist a stable `targetFieldId`, allow same-category references to another text field in the same draft, and reject direct self-reference. Entry editing, safe candidate selection, all nine detail states, target navigation, clearing, and status-specific repair routes are connected. New templates no longer create legacy `entryReference` fields, while existing definitions and entry values remain losslessly compatible.
- Local backup supports restoring the latest encrypted backup and automatically keeps the latest 5 backup files.
- Sync merge data layer matches the Flutter version-vector rules: local/remote dominance, concurrent conflicts, delete-vs-update tombstones, and keep-both conflict copies are covered by JVM tests.
- Remote sync transport now matches the Flutter WebDAV and S3 presigned URL clients: path normalization, Basic Auth, JSON PUT, 404/204 empty remote handling, and timeout/error status mapping are covered by JVM tests.
- Sync settings now mirror the Flutter field contract: provider type, WebDAV/NAS WebDAV, S3 presigned URL, auto-sync, conflict strategy, sync master key, device id, revision, status, and logs. A native client factory can select WebDAV, NAS WebDAV, or S3 presigned URL clients from those settings.
- Sync engine data layer now downloads remote payloads, merges local/remote snapshots, applies remote-dominant results, uploads new revisions, and updates sync revision/status/logs. Missing remote, remote-dominant, and concurrent-conflict upload scenarios are covered.
- A Keystore-wrapped sync secret file store has been added. `webdavPassword` and presigned download/upload URLs can be redacted from normal `SyncSettings` before plaintext storage; JVM tests use a fake cipher to verify the secret file does not contain plaintext secrets, normal config files have no plaintext secrets, and `VaultStore` reloads sync settings.
- An Android instrumented test, `AndroidKeystoreSyncSecretStoreInstrumentedTest`, now verifies on a real device/emulator that the Android Keystore-wrapped sync secret file does not contain plaintext secrets.
- Sync settings UI is wired through `VaultStore` and the Keystore-wrapped secret store. Provider selection only shows the relevant WebDAV/NAS WebDAV or S3 presigned URL fields, so unconfigured providers do not expose irrelevant inputs. The manual sync entry point now connects `SyncClientFactory` with `VaultSyncEngine`, uploads local payloads, applies merge results, and persists revision/status/logs.
- The release merged manifest declares only the `INTERNET`, `USE_BIOMETRIC`, and `USE_FINGERPRINT` normal permissions and keeps `android:allowBackup="false"`; the permissions and Google Play Data safety disclosure baseline is documented in `docs/PERMISSIONS_AND_PRIVACY.md`.
- The adaptive launcher icon includes foreground, background, round icon, and the monochrome layer required for Android 13+ themed icons.
- Debug APK install and launch smoke validation passed on the `Medium_Phone_API_36.1` AVD (Android 16 / API 36). The launcher activity resolves to `.MainActivity`, and the first-screen UI tree shows `Initialize Vault`, master password / confirmation fields, and `Create Vault`.
- Debug APK, unsigned release AAB, androidTest APK build, release manifest processing, the release verification script, JVM tests, and the Keystore-backed key wrapping instrumentation test pass. The device-level validation used the `Medium_Phone_API_36.1` AVD (Android 16 / API 36). Before production release, upload-key signing verification, real WebDAV/S3 end-to-end service validation, and production UI polish must still be completed.
- The P4 entry-reference UI has now been revalidated in a fresh `Medium_Phone_API_36.1` AVD session. Compact validation covered template configuration and stored-value guards, select/replace/clear, target-label search, `resolved`/`empty`/`deleted`/`categoryMismatch` details, view-target, and repair entry points. Expanded validation covered real `resolved` and `categoryMismatch` two-pane details without clipped or overlapping text, buttons, or dialogs. Both compact/expanded baseline layout runs passed and the target app crash buffer was empty. The `missing` state is covered by JVM regression tests; the full tablet/foldable posture and release-device matrix still remains below.

### Requirements

- Android Studio with Android Gradle Plugin 8.11.1 support.
- JDK 21 or later.
- Android SDK Platform 36.
- Android emulator or device running API 26 or later.

This local verification uses JDK 21 at `/Users/joe/Tools/jdk21/zulu-21.jdk/Contents/Home`. `scripts/verify_release.sh` prefers that JDK and fails when the active Java version is lower than 21.

### Develop

From this directory:

```bash
./gradlew :app:assembleDebug
```

If the wrapper bit is lost after copying the checkout, restore it once:

```bash
chmod +x ./gradlew
```

Install on a connected device:

```bash
./gradlew :app:installDebug
```

Run unit tests:

```bash
./gradlew test
```

Run Android instrumented tests on a connected device/emulator:

```bash
./gradlew connectedAndroidTest
```

To compile only the instrumented test APK:

```bash
./gradlew :app:assembleAndroidTest
```

Run the local release gate:

```bash
./scripts/verify_release.sh
```

The script uses JDK 21+, disables the Gradle daemon, enables Kotlin in-process compilation, then runs JVM tests, Debug APK build, androidTest APK build, Release AAB build, and release manifest processing. It checks merged manifest permissions, `allowBackup=false`, the launcher activity, and adaptive icon / round icon / monochrome themed icon resources. When the Play upload key is not configured, it explicitly reports the AAB as unsigned. After configuring the upload key, set `EXPECTED_RELEASE_CERT_SHA256` to gate the signing certificate fingerprint; set `REQUIRE_SIGNED_RELEASE=true` to fail unsigned AABs.

Run the device launch smoke check:

```bash
./scripts/device_launch_smoke.sh
```

The script expects one connected adb device/emulator, or a target selected with `ANDROID_SERIAL=<serial>`. It installs the Debug APK, resolves the launcher activity, clears app data by default, starts the app, verifies the initialize-vault first-screen text, saves `build/device-smoke/ui.xml` and `build/device-smoke/launch.png`, and confirms the crash buffer is empty. Set `RESET_APP_DATA=false` when you intentionally want to keep the current app data.

Run the device layout smoke check:

```bash
./scripts/device_layout_smoke.sh
```

The script expects one connected adb device/emulator, or a target selected with `ANDROID_SERIAL=<serial>`. It installs the Debug APK, temporarily changes `wm size` / `wm density` to compact phone and expanded tablet windows, clears app data, creates a temporary vault, and verifies from the UI tree that compact mode exposes `New`, `Category`, `Tag`, `Sync`, `Backups`, and `Search vault` without rendering the detail pane, while expanded mode renders the `Select an entry` detail placeholder. It saves UI trees, screenshots, and crash-buffer logs under `build/device-layout-smoke/`, verifies the target app did not write to the crash buffer, then restores display settings on exit.

Validate the entry-reference UI separately in both compact and expanded layouts; the baseline layout script does not replace these functional steps:

1. Create a target category and a source category. Add both a text field and an entry-reference field to the source template, and select the reference target category.
2. Create target and source entries. Select a target from the source entry, then verify replacing and clearing the reference.
3. In details, confirm a resolved reference shows only the target label and category, the View action opens the target, and neither UI nor copied content exposes the raw reference ID.
4. Create `missing`, `deleted`, and `categoryMismatch` states by removing, deleting, or moving the target; verify unavailable-state text plus repair and clear actions. Verify an unset value renders as `empty`.
5. Import compatibility data containing an unknown `valueType` or orphaned `templateFieldId`; confirm its stored value is not displayed, copied, or returned by search.
6. In compact mode, confirm editors and detail dialogs scroll and remain actionable without clipping. In expanded mode, confirm list/detail panes and dialogs stay inside the window and fold boundaries.
7. Save screenshots, UI trees, and the target-app crash buffer for each layout, and record the device model, API level, and posture before marking the release check complete.

No Android device/emulator is currently connected, so this documentation update does not claim that the P4 device checks above have passed.

### Local Encryption Verification

Use this flow after changing persistence or crypto code:

1. Build and install the debug app on an emulator or device.
2. Initialize the vault with a master password.
3. Add at least one credential, one server, and one service entry.
4. Force-stop and reopen the app.
5. Verify the wrong password fails and the correct password restores all entries.
6. In Settings, save a Base32 TOTP shared secret, enable 2FA, lock the vault, and verify unlock rejects missing/invalid codes and accepts a current authenticator code.
7. Run manual backup and verify app-private `files/backups/vault-*.json` is created and contains the encrypted envelope, not plaintext vault fields.
8. Run JSON export and verify app-private `files/exports/vault-export-*.json` contains the expected full snapshot JSON.
9. Copy a snapshot JSON file into app-private `files/imports/`, run JSON import, and verify entries/categories/tags/security settings are replaced by the imported snapshot.
10. Inspect the app-private `files/vault.json` through Android Studio Device Explorer or `run-as` on a debug build and confirm plaintext labels, usernames, passwords, tokens, server names, and service names are not present.
11. Repeat the same flow in compact and expanded foldable postures.

### Foldable And Large-Screen Validation

Use at least one foldable emulator profile and one tablet profile before every Android native release:

1. Create an Android Studio emulator such as Pixel Fold or Pixel 9 Pro Fold, plus a medium tablet profile.
2. Install the debug build:

   ```bash
   ./gradlew :app:installDebug
   ```

3. Run the repeatable layout smoke script first to verify the baseline compact/expanded threshold behavior on a normal emulator:

   ```bash
   ./scripts/device_layout_smoke.sh
   ```

4. Validate compact posture: folded/narrow width shows the list first and opens entry details in a dialog.
5. Validate expanded posture: unfolded/wide width shows list and detail panes side by side.
6. Validate a flat vertical separating fold posture: the app uses the two-pane layout and keeps list/detail content on separate sides of the fold.
7. Validate a horizontal separating fold/tabletop posture: the app uses top/bottom regions so list/detail content does not cross the fold.
8. Rotate the device and repeat add/edit/delete/search flows; confirm search text and selected details survive fold/unfold rebuilds.
9. Verify category and tag entry points remain visible in compact/folded layouts and prefill the new-entry form.
10. Repeat entry-reference template configuration, select/replace/clear, five-state details, view, and repair flows in compact and expanded postures; confirm raw IDs, unknown-type values, and orphaned-binding values are never displayed, copied, or returned by search.
11. Verify text remains readable, detail actions remain visible, and no controls are clipped near hinge or window boundaries.
12. Run the app in Android multi-window mode and resize across the compact/expanded threshold.

### Permissions, Backup, and Privacy Disclosure

Current minimal manifest baseline:

- `android.permission.INTERNET`: normal permission for WebDAV, NAS WebDAV, and S3 presigned URL manual sync.
- No external storage, camera, microphone, location, contacts, calendar, SMS, phone, nearby-device, or notification permissions. `USE_BIOMETRIC` and the `androidx.biometric` legacy `USE_FINGERPRINT` compatibility permission are declared for local biometric unlock.
- `android:allowBackup="false"` prevents system cloud backup from copying local encrypted vault, backup, and sync secret files.

Full disclosure and Play Data safety guidance:

```text
docs/PERMISSIONS_AND_PRIVACY.md
```

### Release Build

1. Create or obtain a Play upload keystore.
2. Store signing credentials outside git, for example in `~/.gradle/gradle.properties` or a CI secret store. `app/build.gradle.kts` already supports these optional properties:

   ```properties
   PASSWORD_MANAGER_RELEASE_STORE_FILE=/absolute/path/to/upload-keystore.jks
   PASSWORD_MANAGER_RELEASE_STORE_PASSWORD=...
   PASSWORD_MANAGER_RELEASE_KEY_ALIAS=...
   PASSWORD_MANAGER_RELEASE_KEY_PASSWORD=...
   ```

   When all four properties are present, the release build is signed with the upload key. If any property is missing, the release bundle / APK can still be built as an unsigned artifact for CI compile verification.

3. Pass the version through Gradle properties. `VERSION_NAME` is the public version and `VERSION_CODE` is a positive integer build number that must increase for every release. If omitted, local builds default to `1.0.0` and `1`.
4. Build an Android App Bundle:

   ```bash
   ./gradlew :app:bundleRelease -PVERSION_NAME=1.2.3 -PVERSION_CODE=45
   ```

5. Build an APK only for direct distribution or internal QA:

   ```bash
   ./gradlew :app:assembleRelease -PVERSION_NAME=1.2.3 -PVERSION_CODE=45
   ```

   If only `VERSION_NAME` / `VERSION_CODE` are provided and the four `PASSWORD_MANAGER_RELEASE_*` signing properties are missing, the APK is written to:

   ```text
   app/build/outputs/apk/release/app-release-unsigned.apk
   ```

   `app-release-unsigned.apk` is unsigned and should not be distributed or installed as a normal Android package. After providing a release keystore, the signed APK is written to:

   ```text
   app/build/outputs/apk/release/app-release.apk
   ```

   The AAB artifact is written to:

   ```text
   app/build/outputs/bundle/release/app-release.aab
   ```

   Example signed APK build:

   ```bash
   ./gradlew :app:assembleRelease \
     -PVERSION_NAME=1.0.13 \
     -PVERSION_CODE=14 \
     -PPASSWORD_MANAGER_RELEASE_STORE_FILE=/absolute/path/to/upload-keystore.jks \
     -PPASSWORD_MANAGER_RELEASE_STORE_PASSWORD='...' \
     -PPASSWORD_MANAGER_RELEASE_KEY_ALIAS='...' \
     -PPASSWORD_MANAGER_RELEASE_KEY_PASSWORD='...'
   ```

   For temporary local test installs, Android's debug keystore can produce an installable APK. This package is only for local/QA validation and must not be used for production release or store upload:

   ```bash
   ./gradlew :app:assembleRelease \
     -PVERSION_NAME=1.0.13 \
     -PVERSION_CODE=14 \
     -PPASSWORD_MANAGER_RELEASE_STORE_FILE="$HOME/.android/debug.keystore" \
     -PPASSWORD_MANAGER_RELEASE_STORE_PASSWORD=android \
     -PPASSWORD_MANAGER_RELEASE_KEY_ALIAS=androiddebugkey \
     -PPASSWORD_MANAGER_RELEASE_KEY_PASSWORD=android
   ```

   You can also store the version values in CI secrets or local `~/.gradle/gradle.properties`:

   ```properties
   VERSION_NAME=1.2.3
   VERSION_CODE=45
   ```

6. After providing signing properties, verify the bundle:

   ```bash
   jarsigner -verify -verbose -certs app/build/outputs/bundle/release/app-release.aab
   ```

7. Run the local release gate before each upload candidate. After configuring the upload key, pass the Play upload certificate SHA-256 fingerprint:

   ```bash
   REQUIRE_SIGNED_RELEASE=true \
   EXPECTED_RELEASE_CERT_SHA256=AA:BB:CC:... \
   ./scripts/verify_release.sh
   ```

### Google Play Submission

1. Create the app in Google Play Console.
2. Configure package name, app category, contact details, content rating, target audience, privacy policy URL, and Data safety form.
3. Complete encryption/export compliance answers. The app stores encrypted password vault data and uses cryptography.
4. Upload the signed `.aab` to internal testing first.
5. Test install from Play on a clean device profile.
6. Promote to closed, open, then production tracks after validation.
7. Keep release notes aligned with user-visible changes and never mention unfinished native parity work as shipped.

### Release Checklist

- [x] Native storage is encrypted with AES-256-GCM in a local vault envelope.
- [x] Master key verifier uses PBKDF2-SHA256 with the existing default iteration count.
- [x] Debug APK build passes.
- [x] Debug APK installs and launches to the initialize-vault first screen on the `Medium_Phone_API_36.1` AVD (Android 16 / API 36).
- [x] Device launch smoke script is included to repeatedly verify launcher activity, initialize-vault UI tree, screenshot capture, and an empty crash buffer.
- [x] Device layout smoke script is included to repeatedly verify baseline compact/expanded threshold behavior, compact category/tag entry points, screenshot capture, and the target app crash buffer.
- [x] UI strings are split into English default resources and Chinese `values-zh` resources, including user-visible entry type, sync provider, and conflict-strategy labels.
- [x] Light and night color resources are defined, and the app follows the system dark/light mode by default.
- [x] Release AAB build configuration supports optional Play upload key signing.
- [x] Release AAB builds as an unsigned artifact for CI compile verification when signing properties are absent.
- [x] Local release verification script gates tests, builds, hyphen-free `namespace` / `applicationId`, manifest permissions, `allowBackup=false`, launcher activity, launcher icon resources, and can validate the Play upload certificate fingerprint with `EXPECTED_RELEASE_CERT_SHA256`.
- [x] Instrumented test APK builds and includes the Android Keystore sync secret wrapping device validation case.
- [x] Release manifest processing passes and declares the `INTERNET`, `USE_BIOMETRIC`, and `USE_FINGERPRINT` normal permissions for real remote sync and local biometric unlock.
- [x] Adaptive launcher icon includes foreground, background, round icon, and Android 13+ themed icon monochrome layer.
- [x] JVM tests cover crypto round trip, TOTP verification, JSON snapshot round trip for credential/server/service/tombstone payloads, service account form parsing, Dart fixture compatibility, and fold-aware layout policy.
- [x] TOTP unlock verification matches the Flutter auth package defaults: SHA1, 30-second period, 6 digits, and +/-1 time window.
- [x] Manual backup creates a timestamped app-private copy of the encrypted vault envelope.
- [x] Local backup restores the latest encrypted backup and keeps the latest 5 backups.
- [x] Full snapshot JSON export/import is available through app-private `exports/` and `imports/` directories.
- [x] Item/category JSON import/export supports Keep Copy, Overwrite, and Skip conflict strategies.
- [x] Android category templates support text/entry-reference types and target categories; entry editing supports select, replace, and clear; details support all five states plus view, repair, and clear actions.
- [x] Android details, copy actions, and search suppress raw reference IDs, unknown-type values, and orphaned-binding values; search projects only a resolved target label and category.
- [x] P4 entry-reference behavior has been validated in a fresh compact/expanded AVD session with screenshots, UI trees, and crash-buffer evidence; compact covers the main editing flow and four directly constructible detail states, expanded covers real resolved/category-mismatch two-pane details, and missing is covered by JVM regression tests.
- [x] The P7 field-level reference data contract preserves `targetFieldId` through full snapshots, item/category scoped import/export, and sync payloads; legacy data defaults to an empty value and unknown field types round-trip losslessly.
- [x] P7 first completed the lossless data contract without enabling UI; P8 added the domain resolver and P10 later enabled UI while preserving existing `entryReference` behavior.
- [x] The P8 Android domain resolver covers all nine states, strict one-hop/self-reference guards, and minimal safe projections.
- [x] P8 search projects only the resolved target label, category, and target field name; it never indexes the target field value, raw IDs, payload secrets, or a complete target entry.
- [x] P8 copy import remaps field-reference target entry IDs, category rename propagates target categories, sync preserves metadata and values, and referenced target text fields may be renamed but not deleted or retyped.
- [x] P10 connects initial category creation, category-template editing, entry editing, and explicit details to the nine-state `fieldReference` UI. New categories select the type, target category, and target text field before the first save; legacy `entryReference` templates are read-only while existing values remain editable, and resolved values stay out of candidates, summaries, search, and logs.
- [x] Sync merge data layer covers version-vector dominance, concurrent conflicts, delete-vs-update tombstones, and keep-both conflict copies.
- [x] WebDAV and S3 presigned URL sync transport covers path normalization, Basic Auth, JSON PUT, and network error mapping.
- [x] Sync settings model and provider client factory cover the Flutter field contract, defaults, and unknown-value tolerance.
- [x] Sync engine data layer covers missing remote, remote dominance, concurrent conflict merge/upload, and revision/status/log updates.
- [x] Keystore-wrapped sync secret file store is implemented; sync-sensitive fields can be redacted from normal settings before saving, and JVM tests verify the fake-cipher file has no plaintext secrets.
- [x] Android Keystore-backed key wrapping instrumentation test has passed on the `Medium_Phone_API_36.1` AVD (Android 16 / API 36).
- [x] Sync settings UI uses the Keystore-wrapped secret store, hides irrelevant provider fields, and normal config files do not persist plaintext sync secrets.
- [x] Manual sync entry point is connected to the provider client factory, sync engine, encrypted vault persistence, and sync settings persistence.
- [ ] Real WebDAV/S3 end-to-end service validation is complete.
- [x] Compatibility tests pass against a representative Dart-generated vault payload fixture.
- [x] Network, storage, backup, and biometric permissions are minimized and disclosed.
- [ ] Release AAB is signed by the upload key, installed through an internal track, and tested on API 26, current stable Android, one tablet profile, and one foldable profile in compact and expanded postures.
