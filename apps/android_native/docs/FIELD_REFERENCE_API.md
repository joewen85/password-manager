# Android Field-Level Reference API Contract

## 中文

本文记录 Android 原生客户端在 P7 中新增的数据契约、P8 中新增的领域解析行为，以及 P10 中开放的创建、编辑和九态详情 UI。

### JSON 形状

分类模板字段可使用以下加法式属性：

```json
{
  "id": "source-account-link",
  "name": "Account username",
  "valueType": "fieldReference",
  "targetCategory": "Accounts",
  "targetFieldId": "target-account-username"
}
```

`targetFieldId` 是目标分类模板中字段的稳定、不透明 ID。它不是条目 ID、字段名称或标签；客户端不得根据名称重新计算、规范化或解释该值。

### 兼容规则

- `FieldTemplate.targetFieldId` 的模型默认值是空字符串。
- JSON 缺少 `targetFieldId` 时读取为空字符串，旧快照无需迁移。
- 写出分类模板字段时始终包含 `targetFieldId`。
- 未知且非空的 `valueType` 与 `targetFieldId` 均按原值保留，避免未来客户端数据被旧客户端破坏。
- 现有 `entryReference` 继续把自定义字段值解释为目标条目 ID；P7 不改变该语义。

### 传输范围

同一套分类模板 JSON 编解码用于以下边界，因此这些边界均保留 `targetFieldId`：

- 完整 vault 快照的导入与导出；
- 单条和分类范围的导入与导出；
- `VaultSyncPayload` 中的同步快照。

范围导出只携带当前范围本来包含的条目和模板。`targetFieldId` 不会触发目标条目、目标字段值或其他分类数据的隐式导出。

### P8 解析语义

只有 `valueType` 精确等于 `fieldReference` 的来源模板字段会被识别。解析按以下顺序返回第一个匹配状态：

1. 来源值为空白：`EMPTY`。
2. `targetCategory` 或 `targetFieldId` 为空，或者同分类字段指向自身模板 ID：`INVALID_CONFIGURATION`。
3. 按来源值精确匹配不到目标条目：`MISSING`。
4. 目标条目已软删除：`DELETED`。
5. 目标条目分类与 `targetCategory` 去空格、忽略大小写后不匹配：`CATEGORY_MISMATCH`。
6. 目标分类模板或其中精确 ID 的目标字段不存在：`TARGET_FIELD_MISSING`。
7. 目标字段的兼容类型不是 `text`：`TARGET_FIELD_UNSUPPORTED`。
8. 目标条目没有兼容的字段实例，或实例值为空白：`TARGET_FIELD_EMPTY`。非空 `templateFieldId` 必须与目标模板字段 ID 精确区分大小写匹配；仅真正空的 ID 才按两侧字段名 trim 后忽略大小写回退，非空错误 ID 不回退。
9. 其余情况：`RESOLVED`。

解析严格限制为一跳；目标字段自身是 `fieldReference`、`entryReference` 或未知类型时不会继续递归。结果只可包含目标条目 `id`、`label`、`category` 和目标字段 `id`、`name`、`value` 的最小投影，禁止返回完整 `VaultEntry` 或 payload。

### 搜索、导入与模板生命周期

- 只有 `RESOLVED` 会为来源条目搜索加入目标条目 `label`、`category` 和目标字段 `name`。
- 搜索不加入目标字段 `value`、来源/目标原始 ID、目标 payload、密码、Token、Secret、备注、标签或其他自定义字段。
- Copy import 与 `entryReference` 使用相同的批次目标条目 ID 重映射；`targetFieldId` 保持不变，未包含的目标保留原来源值。
- 分类改名同时传播精确 `fieldReference` 和 `entryReference` 的匹配 `targetCategory`，未知类型不改写。
- 被任一精确 `fieldReference` 引用的目标 `text` 模板字段允许改名，但模板保存和 preset 应用不得删除或改型。
- 同步继续传输包含来源值、`targetCategory` 和 `targetFieldId` 的现有加密快照，不增加 envelope 版本。

### P8 领域边界与 P10 UI

- P10 的 Android 模板编辑 UI 可创建和编辑 `fieldReference`，必须从目标分类模板中选择一个稳定的目标文本字段 ID；同分类可引用其他文本字段，直接自引用会被拒绝。
- 条目编辑使用目标分类约束的安全候选列表。配置无效、目标字段缺失或不支持时进入分类字段修复；其他失败状态进入目标条目重选。
- 解析值只显示在已解锁的显式详情中，不进入候选列表、摘要、搜索或日志。旧 `entryReference` 模板定义只读保留，已有条目值仍可编辑。
- 不提供级联修改或递归解析。
- 不新增数据库、数据库迁移、权限、网络端点、SDK 或数据采集。

## English

This document records the field-level reference data contract added in P7, domain resolution added in P8, and Android UI enabled in P10.

### JSON Shape

A category-template field may carry these additive properties:

```json
{
  "id": "source-account-link",
  "name": "Account username",
  "valueType": "fieldReference",
  "targetCategory": "Accounts",
  "targetFieldId": "target-account-username"
}
```

`targetFieldId` is the stable, opaque ID of a field in the target category template. It is not an entry ID, field name, or tag. Clients must not recalculate, normalize, or interpret it from a name.

### Compatibility Rules

- `FieldTemplate.targetFieldId` defaults to an empty string in the model.
- A missing JSON `targetFieldId` decodes as an empty string, so legacy snapshots require no migration.
- Writers always include `targetFieldId` when encoding a category-template field.
- An unknown non-empty `valueType` and its `targetFieldId` are both preserved verbatim so an older client does not destroy future-client data.
- Existing `entryReference` fields continue to interpret the custom-field value as a target entry ID; P7 does not change that behavior.

### Transport Boundaries

The same category-template JSON codec is used at these boundaries, so each preserves `targetFieldId`:

- full vault snapshot import and export;
- item- and category-scoped import and export;
- the synchronized snapshot inside `VaultSyncPayload`.

A scoped export still includes only the entries and templates already selected by that scope. `targetFieldId` does not implicitly export a target entry, target field value, or data from another category.

### P8 Resolution Semantics

Only a source template field whose `valueType` is exactly `fieldReference` is recognized. Resolution returns the first matching state in this order:

1. Blank source value: `EMPTY`.
2. Blank `targetCategory` or `targetFieldId`, or a same-category field targeting its own template ID: `INVALID_CONFIGURATION`.
3. No exact target-entry ID match: `MISSING`.
4. Soft-deleted target entry: `DELETED`.
5. Target category does not match trimmed `targetCategory` without case sensitivity: `CATEGORY_MISMATCH`.
6. Missing target category template or exact target field ID: `TARGET_FIELD_MISSING`.
7. Target field compatibility type is not `text`: `TARGET_FIELD_UNSUPPORTED`.
8. No compatible target custom-field instance, or its value is blank: `TARGET_FIELD_EMPTY`. A non-empty `templateFieldId` must match the target template-field ID exactly and case-sensitively; only a truly empty ID falls back to comparing both trimmed field names without case sensitivity, and an incorrect non-empty ID never falls back.
9. Otherwise: `RESOLVED`.

Resolution is strictly one hop. A target field that is itself `fieldReference`, `entryReference`, or an unknown type is not followed recursively. Results may contain only a minimal projection of target entry `id`, `label`, and `category` plus target field `id`, `name`, and `value`; they must never return a complete `VaultEntry` or payload.

### Search, Import, And Template Lifecycle

- Only `RESOLVED` contributes the target entry `label` and `category` plus target field `name` to source-entry search.
- Search excludes the target field `value`, source/target raw IDs, target payload, password, token, secret, notes, tags, and other custom fields.
- Copy import uses the same batch target-entry ID remapping as `entryReference`; `targetFieldId` is unchanged, and a target not included in the batch keeps the original source value.
- Category rename propagates a matching `targetCategory` for exact `fieldReference` and `entryReference` fields. Unknown types are not rewritten.
- A target `text` template field referenced by any exact `fieldReference` may be renamed, but template save and preset application must not delete or retype it.
- Sync continues to transport the source value, `targetCategory`, and `targetFieldId` inside the existing encrypted snapshot without an envelope-version change.

### P8 Domain Boundaries and P10 UI

- In P10, both initial category creation and the Android template editor create and edit `fieldReference` fields by selecting a stable target text-field ID from a target category. Initial creation saves the complete definition in one operation; it does not require a temporary text field followed by a second edit. Same-category references may target another text field in the same creation draft; direct self-reference is rejected.
- Entry editing uses a target-category-constrained safe candidate list. Invalid configuration and missing or unsupported target fields route to category-field repair; other failures route to target-entry reselection.
- The resolved value appears only in the unlocked explicit detail view and is excluded from candidates, summaries, search, and logs. Legacy `entryReference` template definitions remain read-only while existing entry values remain editable.
- Cascading mutation and recursive resolution remain unsupported.
- It adds no database, database migration, permission, network endpoint, SDK, or data collection.
