# Windows/Linux 字段到字段关联 API

更新时间：2026-07-29

## 范围

Windows 与 Linux CLI 共用 `apps/native_core/src/vault_cli.cpp`。来源字段必须在创建分类的同一条命令中声明为 `fieldReference`，无需先创建文本字段再改型：

```bash
password-manager-linux add-category "$PASSWORD" Accounts --field Email
password-manager-linux add-category "$PASSWORD" Servers \
  --field-reference "Owner Email" Accounts Email
```

同分类目标文本字段也可以在同一条命令中创建：

```bash
password-manager-linux add-category "$PASSWORD" Servers \
  --field Email --field-reference "Owner Email" Servers Email
```

## 数据契约

来源模板字段保存目标分类规范名称和目标文本字段的稳定 ID：

```json
{
  "id": "source-field-id",
  "name": "Owner Email",
  "valueType": "fieldReference",
  "targetCategory": "Accounts",
  "targetFieldId": "target-email-field-id"
}
```

来源条目字段保存所选目标条目 ID，并通过自身 `templateFieldId` 绑定来源模板字段：

```bash
password-manager-linux add-entry "$PASSWORD" \
  --label "Production Server" --category Servers \
  --field-reference "Owner Email" "Production Account"
```

目标条目可使用精确 ID，或使用目标分类内唯一的名称。CLI 拒绝缺失分类、缺失或非文本目标字段、重复来源字段、直接自引用、失效目标和歧义名称；命令失败时不会残留分类或条目。

## 兼容与展示

- `fieldReference` 只解析一跳，不递归解析目标引用字段。
- `show-entry` 覆盖九种状态；只有 `resolved` 在显式解锁详情中显示配置目标文本字段的值。
- `list` 和搜索不索引目标字段值、原始引用 ID 或目标秘密。
- `export-snapshot` 是无损明文导出边界，会保留引用 ID 和 `targetFieldId`，必须按敏感数据处理。
- 新属性保存在现有加密 JSON snapshot 中；旧数据通过 decoder 默认值读取，不存在数据库 schema，也不需要迁移文件。

## 验证

```bash
cd apps/windows_native && make test
cd apps/linux_native && make test
```

共享 smoke 同时覆盖同分类和跨分类成功创建、稳定字段 ID、条目绑定、直接自引用及无效目标原子拒绝。
