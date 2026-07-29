# HarmonyOS 字段到字段关联数据 API

更新时间：2026-07-29

## 1. 范围

本阶段为 HarmonyOS 提供字段到字段关联的数据契约兼容层。它负责在本地加密存储、同步、全量及 scoped 导入导出中无损保留目标字段标识，但不改变现有 `entryReference` 的 UI、候选选择、解析、搜索或展示语义。

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
- 所有写同步客户端都能无损保留 `targetFieldId` 后，才可以开放创建 `fieldReference` 的 UI。

## 4. HarmonyOS 路径

| 路径 | 保证 |
|---|---|
| 模板创建 | 新文本字段初始化 `targetFieldId = ""` |
| 模板规范化和 upsert | 缺失值补空，已有值原样保留 |
| 分类模板编辑 | 未知类型只读保留，编辑合并不丢扩展元数据 |
| 本地加密存储 | 属性随现有 vault JSON 加密 envelope 保存 |
| 同步合并 | 通过共享模板规范化路径保留属性 |
| 全量导入导出 | 属性随分类模板 JSON 往返 |
| 单条/分类导入导出 | version 2 scoped payload 随源分类模板往返 |

## 5. 权限与隐私

该属性不引入新权限、网络端点、SDK、数据库或明文存储。HarmonyOS 权限仍只有 `ohos.permission.INTERNET` 和 `ohos.permission.ACCESS_BIOMETRIC`。

兼容层不会解析或投影目标字段内容。scoped 导出也不会因为字段引用自动包含目标条目；目标条目的密码、Token、Secret、备注或其他自定义字段不得进入列表、搜索、日志或剪贴板。

## 6. 验证

```bash
node scripts/harmony_field_reference_contract_compat_tests.mjs
./scripts/harmony_preflight.sh
./scripts/harmony_build_hap.sh default
```
