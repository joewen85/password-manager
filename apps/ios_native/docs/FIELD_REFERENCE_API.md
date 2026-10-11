# iOS Field-Level Reference API

## 中文

`PasswordManageriOSCore` 已提供字段级关联的领域、Store 和 SwiftUI 交互。独立分类创建与条目编辑器内联创建均可在首次保存前配置 `text` 或 `fieldReference`，并选择目标分类和目标文本字段。共享数据格式见 `../../../docs/FIELD_REFERENCE_CONTRACT.md`。

### 解析 API

```swift
resolveFieldReference(
    sourceEntry: VaultEntry,
    field: CustomField,
    categoryTemplates: [CategoryTemplate],
    entries: [VaultEntry]
) -> FieldReferenceResolution?
```

只有来源字段匹配 `valueType` 精确为 `fieldReference` 的模板字段时才返回解析结果。状态优先级为：

1. `empty`
2. `invalidConfiguration`
3. `missing`
4. `deleted`
5. `categoryMismatch`
6. `targetFieldMissing`
7. `targetFieldUnsupported`
8. `targetFieldEmpty`
9. `resolved`

目标条目 ID 与 `targetFieldId` 精确区分大小写；分类去除首尾空白后忽略大小写。`targetCategory`、`targetFieldId` 必须非空，同分类且来源字段 ID 等于目标字段 ID 时视为自引用无效配置。目标模板字段必须为兼容 `text` 类型，不递归解析其他关联。

找到目标条目后，结果最多保留目标条目 ID、名称、分类和目标字段 ID；找到目标模板字段后可增加字段名。只有 `resolved` 写入目标字段值，其他状态的 `fieldValue` 为空。结果不包含完整 `VaultEntry`、payload 或无关字段。

目标字段实例优先按非空 `templateFieldId` 精确匹配。只有 legacy 实例的 `templateFieldId` 为空时，才回退到去空白、忽略大小写的字段名匹配。

### Store 与生命周期 API

- `VaultStore.addCategory(_:preset:customFields:)` 接收完整 `FieldTemplate`，在任何分类 mutation 或持久化前验证空名、重名和字段关联配置。旧的字段名重载继续兼容并委托给完整模板重载。
- 创建 UI 把当前分类草稿和其他文本字段加入 prospective templates，因此可安全选择同分类目标；来源字段自身、空目标或非文本目标会被拒绝。
- `VaultEntry.withFieldReferenceSearchProjection(categoryTemplates:entries:)`：先保留原 `entryReference` 搜索行为，再仅为已解析 `fieldReference` 加入目标名称、分类和字段名。
- `VaultEntry.remappingFieldReferenceIDs(using:template:)`：copy import 对同批次目标条目 ID 做重映射；`targetFieldId` 不变，未映射值按原值保留。
- `fieldReferenceTargetFieldIDs(targetCategory:templates:)`：按分类返回被引用的稳定目标字段 ID。
- `VaultStore.categoryTemplateReferencedTargetFieldIDs(_:)`：Store 级依赖查询。
- `propagateFieldReferenceCategoryRename(templates:from:to:)`：只更新精确 `fieldReference` 的匹配目标分类，不改字段 ID、目标字段 ID 或来源值。

分类模板保存会原子拒绝删除被引用的现有目标文本字段，或把它改成其他类型；保持相同 ID 的字段改名允许通过。已经指向缺失或非文本字段的旧错误配置不会永久阻塞模板编辑。

### 行为边界

- 新建模板使用 `fieldReference`，旧 `entryReference` 定义只读兼容；已有值仍可选择、更换或清空。
- 解析值只在已解锁的显式详情中展示，不进入候选、摘要、搜索或日志。
- 不改变现有 `entryReference` 解析、候选、详情或搜索行为。
- 不支持递归、级联修改或隐式导出目标条目。
- 快照、范围导入导出和同步继续使用现有加密 JSON 形状与 envelope 版本。

## English

`PasswordManageriOSCore` now provides field-reference domain behavior, Store validation, and SwiftUI interaction. Standalone and entry-editor inline category creation configure `text` or `fieldReference` fields plus target category and target text field before the first save. See `../../../docs/FIELD_REFERENCE_CONTRACT.md` for the shared data format.

`resolveFieldReference(sourceEntry:field:categoryTemplates:entries:)` recognizes only an exact `fieldReference` source template type and applies this precedence: `empty`, `invalidConfiguration`, `missing`, `deleted`, `categoryMismatch`, `targetFieldMissing`, `targetFieldUnsupported`, `targetFieldEmpty`, then `resolved`.

Entry IDs and `targetFieldId` are exact and case-sensitive. Categories are trimmed and compared without case sensitivity. Configuration requires nonblank `targetCategory` and `targetFieldId`; a same-category source field targeting its own stable field ID is invalid. The target template field must be compatible `text`, and resolution is one hop only.

After finding the target entry, the result contains at most entry ID, label, category, and target field ID. The field name is added after finding the target template field. Only `resolved` populates `fieldValue`; every other state keeps it empty. No complete target entry, payload, or unrelated field is returned. Target instances use an exact non-empty `templateFieldId`, with the legacy name fallback available only for an empty binding.

Store behavior:

- `VaultStore.addCategory(_:preset:customFields:)` accepts complete `FieldTemplate` values and validates blank/duplicate names and reference configuration before taxonomy mutation or persistence. The legacy name-only overload delegates to it.
- Creation UI adds the current category draft and its other text fields to prospective templates, enabling same-category targets while rejecting the source field itself, blank targets, and unsupported target types.
- `withFieldReferenceSearchProjection` preserves legacy entry-reference search and adds only resolved target label, category, and field name.
- `remappingFieldReferenceIDs` remaps a target entry included in the same copy-import batch; `targetFieldId` and unmapped values remain unchanged.
- `fieldReferenceTargetFieldIDs` and `categoryTemplateReferencedTargetFieldIDs` expose stable target-field dependencies.
- `propagateFieldReferenceCategoryRename` updates matching exact field-reference target categories only.
- Template save atomically rejects deletion or retyping of an existing referenced target text field, while stable-ID rename remains allowed. Existing references to already missing or unsupported targets do not permanently block editing.

New templates use `fieldReference`; legacy `entryReference` definitions remain read-only-compatible and existing values remain selectable, replaceable, and clearable. Resolved values appear only in unlocked explicit details and stay out of candidates, summaries, search, and logs. This UI adds no recursion, cascading mutation, implicit target export, envelope change, or change to existing `entryReference` behavior.
