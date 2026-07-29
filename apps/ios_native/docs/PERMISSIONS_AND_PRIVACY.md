# iOS Permissions And Privacy

## 中文

该文件记录字段级关联创建与解析对 iOS 权限和隐私基线的影响。

- 字段级关联创建与解析只处理已解锁的加密 vault JSON 和内存分类模板，不新增网络端点、第三方 SDK、数据库、数据库迁移或数据采集。
- `PasswordManageriOS.entitlements` 无需新增能力。P8 不访问相机、麦克风、定位、通讯录、照片或其他受保护系统资源。
- `PrivacyInfo.xcprivacy` 现有 UserDefaults `CA92.1` required-reason 声明保持不变。P8 不调用新的 required-reason API，不增加 tracking domain、追踪或收集数据类型。
- resolver 领域结果仅包含目标条目 ID、名称、分类和指定目标字段的 ID、名称、值，不包含完整目标 entry 或 payload。
- 创建 UI 只列出分类名和兼容文本字段名，不读取目标条目或目标值；稳定字段 ID 只作为选择状态和加密快照元数据。
- 目标字段值属于敏感 vault 内容，只用于已解锁内存中的单跳解析，并仅在显式的 `resolved` 详情边界按需展示；不进入创建配置、搜索或日志。
- 搜索只在解析成功时投影目标条目名称、分类和目标字段名，不索引来源/目标 ID、`targetFieldId`、目标字段值、密码、Token、Secret、备注、标签或无关字段。
- copy import、分类改名传播和目标字段依赖保护只是本地数据完整性操作，不隐式导出或上传关联目标。
- 完整快照和显式范围导出仍按现有产品行为处理敏感 vault 数据；字段关联不会扩大用户选择的导出范围。

因此该创建能力无需修改 entitlement 或 privacy manifest。后续若扩大目标值展示/复制范围、加入 telemetry，或引入新的 required-reason API，必须重新审查并更新披露。

## English

Field-reference creation and resolution operate only on encrypted vault JSON and in-memory category templates after unlock. They add no endpoint, third-party SDK, database, migration, or data collection.

- `PasswordManageriOS.entitlements` needs no new capability, and P8 accesses no protected camera, microphone, location, contacts, photos, or similar resource.
- The existing UserDefaults `CA92.1` declaration in `PrivacyInfo.xcprivacy` remains sufficient. P8 adds no required-reason API, tracking domain, tracking, or collected-data category.
- The domain resolver returns only target entry ID/label/category and selected target field ID/name/value, never a complete target entry or payload.
- Creation UI lists only category names and compatible text-field names. It does not read target entries or values; stable field IDs remain selection state and encrypted-snapshot metadata.
- The target field value remains sensitive unlocked-vault content and appears only at the explicit `resolved` detail boundary. It is excluded from creation configuration, search, and logs.
- Successful search uses only target label, category, and field name. It excludes source/target IDs, `targetFieldId`, target value, passwords, tokens, secrets, notes, tags, and unrelated fields.
- Copy-import remapping, category-rename propagation, and target-field dependency protection are local integrity operations and never implicitly export or upload a target.

No entitlement or privacy-manifest change is required for this creation capability. Reassess these declarations if target-value display/copy scope expands, telemetry is added, or a new required-reason API is introduced.
