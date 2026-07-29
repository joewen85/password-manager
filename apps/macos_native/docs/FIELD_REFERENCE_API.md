# macOS Field-Level Reference API

## 中文

`PasswordManagerMacOSApp` 已提供字段级关联的领域、Store 和原生创建 UI。主创建菜单、分类/标签管理以及条目编辑器的内联分类创建都可在首次保存前将自定义字段设为 `text` 或 `fieldReference`，并选择目标分类和目标文本字段。共享数据格式见 `../../../docs/FIELD_REFERENCE_CONTRACT.md`。

`resolveFieldReference(sourceEntry:field:categoryTemplates:entries:)` 只识别 `valueType` 精确为 `fieldReference` 的来源模板字段，按 `empty`、`invalidConfiguration`、`missing`、`deleted`、`categoryMismatch`、`targetFieldMissing`、`targetFieldUnsupported`、`targetFieldEmpty`、`resolved` 的顺序返回。

目标条目 ID 与 `targetFieldId` 精确区分大小写；分类去除首尾空白后忽略大小写。配置要求 `targetCategory` 和 `targetFieldId` 非空，同分类来源字段指向自身字段 ID 时无效。目标模板字段必须为兼容 `text`，解析严格限制为一跳。

找到目标条目后，结果最多保留目标条目 ID、名称、分类和目标字段 ID；找到目标模板字段后可增加字段名。只有 `resolved` 写入目标字段值，其他状态的 `fieldValue` 为空。结果不返回完整目标 entry、payload 或无关字段。目标实例优先按非空 `templateFieldId` 精确匹配；只有 legacy 空绑定可回退到去空白、忽略大小写的字段名。

Store API 与行为：

- `VaultStore.addCategory(_:preset:customFields:)` 接收完整 `FieldTemplate`，在任何分类 mutation 或持久化前构造 prospective template 并验证全部字段关联。旧 `customFieldNames` 重载继续兼容并委托完整字段重载。
- 创建 UI 将当前分类草稿及其其他文本字段加入 prospective templates，因此支持同分类关联；来源字段自身不会成为文本目标，自引用或不完整目标会被 Store 原子拒绝。
- `withFieldReferenceSearchProjection` 保留既有 `entryReference` 搜索，并只为已解析字段关联加入目标名称、分类和字段名。
- `remappingFieldReferenceIDs` 在 copy import 中重映射同批次目标条目 ID，保持 `targetFieldId` 和未映射值不变。
- `fieldReferenceTargetFieldIDs` 与 `categoryTemplateReferencedTargetFieldIDs` 返回稳定目标字段依赖。
- `propagateFieldReferenceCategoryRename` 及 `VaultStore.renameCategory` 更新精确匹配的字段关联目标分类，不改字段 ID、`targetFieldId` 或来源值。
- 模板保存会原子拒绝删除或改型被引用的现有目标文本字段，但允许保持相同 ID 的改名。已经指向缺失或不支持字段的旧配置不会永久阻塞编辑。

该创建切片不增加递归、级联修改、隐式目标导出或同步 envelope 版本，也不改变既有 `entryReference` 行为。

## English

`PasswordManagerMacOSApp` now provides field-level reference domain behavior, Store validation, and native creation UI. The main create sheet, taxonomy manager, and entry editor's inline category creation can configure each new field as `text` or `fieldReference` and select its target category and target text field before the category is first saved. See `../../../docs/FIELD_REFERENCE_CONTRACT.md` for the shared format.

`resolveFieldReference(sourceEntry:field:categoryTemplates:entries:)` recognizes only an exact `fieldReference` source type and applies this order: `empty`, `invalidConfiguration`, `missing`, `deleted`, `categoryMismatch`, `targetFieldMissing`, `targetFieldUnsupported`, `targetFieldEmpty`, then `resolved`.

Entry IDs and `targetFieldId` are exact and case-sensitive; categories are trimmed and case-insensitive. Configuration requires nonblank target category and field ID, and same-category self-reference is invalid. Only a compatible text target is supported, with no recursive resolution.

Found-entry states retain only entry ID/label/category and target field ID. The field name is added after its template is found. Only `resolved` populates the field value. No complete target entry, payload, or unrelated field is returned. Target values prefer an exact non-empty template binding and use the legacy normalized-name fallback only for an empty binding.

`VaultStore.addCategory(_:preset:customFields:)` accepts complete `FieldTemplate` values and validates a prospective template before any taxonomy mutation or persistence. The legacy name-only overload remains compatible and delegates to it. Creation UI includes the current category draft and its other text fields in that prospective template, enabling same-category targets while excluding direct self-reference.

Search exposes only resolved target label/category/field name. Copy import remaps included target-entry IDs without changing `targetFieldId`. Dependency APIs identify referenced target fields, category rename propagates exact field-reference constraints, and template save atomically rejects deletion or retyping of an existing referenced text target while allowing stable-ID rename.

This creation slice adds no recursion, cascading mutation, implicit target export, sync-envelope change, or change to existing `entryReference` behavior.
