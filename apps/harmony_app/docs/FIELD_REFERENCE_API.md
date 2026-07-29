# HarmonyOS 字段到字段关联数据 API

更新时间：2026-07-29

## 1. 范围

P8 为 HarmonyOS 提供字段到字段关联的数据契约、内部 resolver 和生命周期行为。P9 已在相同契约上开放创建、编辑、条目选择和九态详情 UI。它在本地加密存储、同步、全量及 scoped 导入导出中无损保留目标字段标识，并支持安全解析、搜索投影、复制导入重映射、分类改名和目标字段保护。

新建模板字段时直接选择 `text` 或 `fieldReference`。选择 `fieldReference` 后必须在首次保存前选定目标分类和稳定目标文本字段；新建流程不再创建旧 `entryReference`。已有 `entryReference` 定义和值继续无损兼容。

## 2. 数据形状

字段到字段关联由源分类模板字段定义：

```json
{
  "id": "template_owner_email",
  "name": "Owner Email",
  "valueType": "fieldReference",
  "targetCategory": "Accounts",
  "targetFieldId": "template_account_email"
}
```

源条目自定义字段仍保存目标条目 ID：

```json
{
  "id": "custom_owner_email",
  "templateFieldId": "template_owner_email",
  "name": "Owner Email",
  "value": "account_entry_01"
}
```

字段含义：

| 属性 | 含义 |
|---|---|
| `FieldTemplate.id` | 源模板字段的稳定、不透明 ID |
| `valueType` | `fieldReference` 表示字段到字段关联；现有 `entryReference` 语义保持不变 |
| `targetCategory` | 目标条目所属分类 |
| `targetFieldId` | 目标分类模板中的稳定字段 ID，不是目标字段值 |
| `CustomField.value` | 目标条目 ID，不改为目标字段 ID |

## 3. 兼容规则

- 旧数据缺失 `targetFieldId` 时规范化为 `""`，无需 schema 或数据库迁移。
- 非空 `targetFieldId` 按不透明字符串原样保留，不重新生成、不根据字段名推导。
- 未知且非空的 `valueType` 按原值保留，其 `targetCategory` 和 `targetFieldId` 同样不得丢失。
- 当前客户端不认识的字段类型保持只读；不得回退为文本字段显示、复制或索引其存值。
- `entryReference` 继续只关联目标条目，不因出现新属性而改变行为。
- 目标分类模板中的 `targetFieldId` 只做大小写敏感的精确 ID 匹配，不按字段名猜测目标模板字段。
- 目标条目中的 `CustomField.templateFieldId` 非空时同样必须大小写敏感精确匹配。只有属性缺失或值为真正的空字符串时，才按目标模板字段名称 trim 后忽略大小写回退；空白字符串属于非空不透明 ID，不触发回退。
- 所有维护端已经能够无损保留 `targetFieldId`，并采用相同 resolver 语义，因此 P9 UI 可以创建和编辑 `fieldReference`；旧客户端不得继续写入已经包含该类型的同步保险库。

## 4. 九态解析

解析优先级固定如下：

| 顺序 | 状态 | 条件 |
|---|---|---|
| 1 | `EMPTY` | 源字段值 trim 后为空 |
| 2 | `INVALID_CONFIGURATION` | 目标分类或目标字段 ID 缺失，或字段直接引用自身 |
| 3 | `MISSING` | 源字段保存的目标条目 ID 不存在 |
| 4 | `DELETED` | 目标条目存在但已软删除 |
| 5 | `CATEGORY_MISMATCH` | 活动目标条目不在配置分类中 |
| 6 | `TARGET_FIELD_MISSING` | 目标分类模板不存在对应 `targetFieldId` |
| 7 | `TARGET_FIELD_UNSUPPORTED` | 目标模板字段不是 `text` |
| 8 | `TARGET_FIELD_EMPTY` | 目标条目缺少对应字段实例，或字段值 trim 后为空 |
| 9 | `RESOLVED` | 目标条目、分类、文本字段定义和字段值均有效 |

找到目标条目后，resolver 只构造以下内部最小投影：

```json
{
  "id": "account_entry_01",
  "label": "Production Account",
  "category": "Accounts",
  "fieldId": "template_account_email",
  "fieldName": "Email",
  "value": "ops@example.com"
}
```

`fieldName` 仅在目标模板字段存在后填充，`value` 仅在 `RESOLVED` 时填充。投影不包含目标 entry、payload、密码、Token、Secret、备注、标签或其他自定义字段；内部 ID 也不得直接显示或复制给用户。

## 5. HarmonyOS 路径

| 路径 | 保证 |
|---|---|
| 模板创建 | 文本字段初始化 `targetFieldId = ""`；字段关联在首次保存前选择目标分类和目标文本字段并保存稳定 ID |
| 模板规范化和 upsert | 缺失值补空，已有值原样保留 |
| 分类模板编辑 | 未知类型只读保留，编辑合并不丢扩展元数据 |
| 本地加密存储 | 属性随现有 vault JSON 加密 envelope 保存 |
| 同步合并 | 通过共享模板规范化路径保留属性 |
| 全量导入导出 | 属性随分类模板 JSON 往返 |
| 单条/分类导入导出 | version 2 scoped payload 随源分类模板往返 |
| 安全搜索 | 仅在 `RESOLVED` 时投影目标名称、分类和目标字段名称，不索引目标字段值或 ID |
| 复制导入 | `CustomField.value` 中的目标条目 ID 按批次映射，`targetFieldId` 不变 |
| 分类改名 | 同时更新 `entryReference` 和 `fieldReference` 的 `targetCategory`，保持字段 ID 不变 |
| 目标字段保护 | 被 `fieldReference` 指向的目标文本字段不能静默删除或改型 |

## 6. 权限与隐私

该属性不引入新权限、网络端点、SDK、数据库或明文存储。HarmonyOS 权限仍只有 `ohos.permission.INTERNET` 和 `ohos.permission.ACCESS_BIOMETRIC`。

resolver 只读取配置的单个文本字段。目标字段值仅在 `RESOLVED` 的已解锁显式详情中显示；它不进入候选、摘要、搜索、日志或隐式导出，也不会由该关系 UI 写入剪贴板，非成功态不携带该值。scoped 导出不会因为字段引用自动包含目标条目；目标条目的密码、Token、Secret、备注或其他自定义字段不得进入列表、搜索、日志或剪贴板。

## 7. 验证

```bash
node scripts/harmony_field_reference_contract_compat_tests.mjs
node scripts/harmony_reference_resolver_tests.mjs
node scripts/harmony_reference_operations_tests.mjs
node scripts/harmony_field_reference_ui_tests.mjs
./scripts/harmony_preflight.sh
./scripts/harmony_build_hap.sh default
```
