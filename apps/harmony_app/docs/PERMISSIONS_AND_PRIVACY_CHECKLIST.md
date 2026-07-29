# HarmonyOS 6 权限与隐私核查清单

更新时间：2026-07-28

## 1. 权限最小化结论

当前声明 2 个权限：

- `ohos.permission.INTERNET`
- `ohos.permission.ACCESS_BIOMETRIC`

声明位置：

- `entry/src/main/module.json5 -> module.requestPermissions`

用途说明：

- 用于 WebDAV / NAS WebDAV / S3 预签名 URL 的同步请求。
- 用于启用和使用系统 Face/Fingerprint 生物识别解锁。

未声明权限（确认不需要）：

- 通讯录、短信、定位、相机、麦克风、文件管理等敏感权限。

## 2. 数据处理与本地安全

- 主密码仅用于本地派生密钥，不上传。
- 密码库数据以密文 envelope 存储（PBKDF2 + AES-GCM 路径）。
- 2FA Secret 与业务条目随加密载荷统一密文落盘。
- 解锁失败保护状态（失败次数、锁定截止时间）存储在 envelope 元信息中，不包含明文账号密码。
- 生物识别解锁凭据不保存主密码明文；主密码通过 HUKS AES-GCM 硬件密钥加密后落盘，解密需要 Face/Fingerprint 认证 token。
- 生物识别硬件密钥设置为新增生物特征后失效，失效后需要用户用主密码重新启用生物识别解锁。

## 3. 网络与隐私边界

- 同步链路仅使用用户配置的 HTTPS 端点（WebDAV/S3 预签名 URL）。
- 同步日志已做敏感信息脱敏（password/token/authorization/Bearer）。
- 应用默认不上传遥测或统计数据。
- 字段关联只在现有加密 vault JSON 内保存模板元数据和稳定条目 ID；字段到字段关联额外保存不透明的 `targetFieldId` 目标模板字段 ID，不新增权限、网络端点、SDK 或数据采集。
- `targetFieldId` 不是目标字段值。P8 resolver 只在保险库已解锁且关系完整解析时读取配置的单个文本字段，并返回最小投影；不会返回完整目标条目、payload 或其他自定义字段。
- `fieldReference` 搜索投影仅包含目标条目名称、分类和目标字段名称，不索引目标字段值、目标条目 ID、`targetFieldId` 或任何其他秘密。复制导入只重映射源字段中保存的目标条目 ID，`targetFieldId` 保持不变。
- 单条/分类导出不得因引用而隐式导出其他条目，搜索与日志不得索引或记录被引用目标的密码、Token、Secret 等敏感字段；完整规则见 `../../../docs/FIELD_REFERENCE_CONTRACT.md`。
- 字段关联选择器、详情和列表摘要只显示目标名称、分类或失效状态；不得显示、复制或记录存储的引用 ID。
- 模板删除、来源分类删除或模板绑定失配后，带非空 `templateFieldId` 的孤儿字段必须按不支持类型只读保留，不得回退为普通文本展示、复制、编辑或索引原值。
- 解析结果和候选列表只投影目标的 `id`、`label`、`category`，不得把目标 payload、密码、Token、Secret、备注、标签或自定义字段传给 UI。

## 4. 发布前核对项

1. 在 DevEco Product 配置中确认 `INTERNET` 与 `ACCESS_BIOMETRIC` 权限与发布包一致。
2. 隐私政策中明确：
   - 数据主要本地加密保存；
   - 同步仅在用户显式配置后生效；
   - 生物识别仅用于本机解锁，不上传生物识别数据；
   - 不采集与业务无关个人信息。
3. 真机回归时验证：
   - 未启用生物识别时仍可使用主密码离线解锁；
   - 启用生物识别后可通过系统 Face/Fingerprint 解锁；
   - 新增或删除系统生物特征后，旧生物识别解锁凭据失效；
   - 开启同步后网络功能正常；
   - 日志中不出现 token/secret 明文；
   - 字段关联选择器、详情、摘要、搜索和剪贴板不出现引用 ID 或目标秘密；
   - `fieldReference` 九态 resolver 不返回完整目标条目，非 `RESOLVED` 状态不携带目标字段值；
   - `fieldReference` UI 尚未开放，现有 UI 将其继续视为只读不支持类型，且搜索、日志和剪贴板不暴露 `targetFieldId` 或目标字段值；
   - scoped 导出不会因为关联自动包含目标条目。
