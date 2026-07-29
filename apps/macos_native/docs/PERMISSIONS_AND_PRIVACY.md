# macOS Permissions And Privacy

## 中文

字段级关联创建与解析只在保险库解锁后处理现有加密 JSON 和内存中的分类模板，不新增网络端点、第三方 SDK、数据库、迁移、数据采集或追踪。

- `ReleaseSupport/PrivacyInfo.xcprivacy` 继续声明不追踪、无 tracking domains、无收集数据类型和无 required-reason API。P8 不改变该结论。
- 现有 entitlements 仅覆盖产品已有的 App Sandbox、用户选择文件和同步所需网络能力；P8 不新增 entitlement 或系统权限。
- resolver 只返回目标条目 ID、名称、分类和指定目标字段的 ID、名称、值，不返回完整 entry 或 payload。
- 创建 UI 只列出分类名和兼容文本字段名，不读取目标条目或目标字段值；稳定字段 ID 仅作为 Picker selection 和加密快照元数据，不直接展示给用户。
- 目标字段值是敏感 vault 内容，仅在已解锁内存中用于单跳解析，并只在既有 `resolved` 详情边界按需显示；它不进入创建配置 UI、搜索或日志。
- 搜索只投影成功解析目标的名称、分类和字段名，不索引来源/目标 ID、`targetFieldId`、目标字段值、密码、Token、Secret、备注、标签或其他字段。
- copy import、分类改名传播和目标字段保护是本地完整性操作，不会隐式导出或上传关联目标。
- 完整快照与用户显式选择的范围导出仍按既有敏感数据流程处理，字段关联不会扩大导出范围。

因此该创建能力无需修改 privacy manifest 或 entitlements。后续若扩大目标值的展示/复制范围、加入 telemetry 或调用 required-reason API，应重新审查隐私声明。

## English

Field-reference creation and resolution operate only on the existing encrypted JSON and in-memory category templates after vault unlock. They add no endpoint, third-party SDK, database, migration, collection, or tracking.

- `ReleaseSupport/PrivacyInfo.xcprivacy` continues to declare no tracking, tracking domains, collected data types, or required-reason API. P8 does not change that conclusion.
- Existing entitlements cover the product's current App Sandbox, user-selected file, and sync-network capabilities. P8 adds no entitlement or system permission.
- The resolver returns only target entry ID/label/category and selected target field ID/name/value, never a complete entry or payload.
- Creation UI lists only category names and compatible text-field names. It does not read target entries or target values; stable field IDs remain Picker state and encrypted-snapshot metadata rather than visible UI text.
- The target value remains sensitive unlocked-vault content and is shown only at the existing explicit `resolved` detail boundary. It is excluded from creation configuration, search, and logs.
- Successful search uses only target label, category, and field name. It excludes source/target IDs, `targetFieldId`, target value, passwords, tokens, secrets, notes, tags, and unrelated fields.
- Copy-import remapping, category-rename propagation, and target-field protection are local integrity operations and never implicitly export or upload a target.

No privacy-manifest or entitlement change is required for this creation capability. Reassess if target-value display/copy scope expands, telemetry is introduced, or a required-reason API is added.
