# Android Field-Level Reference API Contract

## 中文

本文记录 Android 原生客户端在 P7 中新增的字段级关联数据契约。P7 只保证数据可读取、写入和无损传递，不提供 UI 或解析行为。

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

### P7 边界

- Android 模板编辑 UI 不创建 `fieldReference`。
- Android 条目编辑、详情、搜索和复制逻辑不解析 `fieldReference`。
- 本阶段不定义字段级关联的解析状态、级联行为或用户交互。
- 不新增数据库、数据库迁移、权限、网络端点、SDK 或数据采集。

## English

This document records the field-level reference data contract added to the native Android client in P7. P7 guarantees only lossless read, write, and transport behavior; it does not add UI or resolution behavior.

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

### P7 Boundaries

- The Android template editor does not create `fieldReference` fields.
- Android entry editing, detail, search, and copy logic does not resolve `fieldReference`.
- This phase defines no field-level resolution states, cascading behavior, or user interaction.
- It adds no database, database migration, permission, network endpoint, SDK, or data collection.
