# Windows/Linux 字段关联权限与隐私说明

更新时间：2026-07-29

## 权限结论

字段到字段关联不新增 Windows 或 Linux 系统权限、网络端点、后台服务、SDK 或数据采集。它只在已解锁的本地 vault 内读取分类模板、目标条目和配置的单个目标文本字段。

远端同步继续使用用户显式配置的 WebDAV 或对象存储端点以及现有 libcurl 链路。字段关联不会触发额外网络请求，也不会自动上传被引用条目。

## 数据边界

- 来源模板保存 `targetCategory` 和不透明的 `targetFieldId`；来源字段值保存目标条目 ID。这些标识都随现有 encrypted envelope 加密落盘。
- 目标字段值只在 `resolved` 的显式 `show-entry` 结果中显示；`--show-secret` 不扩大字段关联的投影范围。
- 列表、搜索和同步日志不得包含目标字段值、原始引用 ID、目标密码、Token、Secret、备注或无关字段。
- 非成功状态不得携带目标字段值；未知字段类型和孤儿绑定不得回退为普通文本显示。
- `export-snapshot` 为用户主动触发的无损明文数据导出，会包含引用标识；输出文件必须保存到受信任位置。

## 凭据输入

生产环境优先使用 `--password-stdin`、`--totp-stdin`、`--remote-password-stdin`、`--secret-key-stdin` 和 presigned URL stdin 参数，避免主密码及同步凭据进入进程参数和 shell 历史。字段关联本身不保存这些凭据。

Windows Credential Manager、DPAPI、Linux Secret Service 和图形界面权限集成不属于当前 terminal-native 切片；发布说明不得把可移植 core 门禁表述为对应平台实机权限验证。
