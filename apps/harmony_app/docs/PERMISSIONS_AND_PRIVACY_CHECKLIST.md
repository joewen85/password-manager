# HarmonyOS 6 权限与隐私核查清单

更新时间：2026-02-28

## 1. 权限最小化结论

当前仅声明 1 个权限：

- `ohos.permission.INTERNET`

声明位置：

- `entry/src/main/module.json5 -> module.requestPermissions`

用途说明：

- 用于 WebDAV / NAS WebDAV / S3 预签名 URL 的同步请求。

未声明权限（确认不需要）：

- 通讯录、短信、定位、相机、麦克风、文件管理等敏感权限。

## 2. 数据处理与本地安全

- 主密码仅用于本地派生密钥，不上传。
- 密码库数据以密文 envelope 存储（PBKDF2 + AES-GCM 路径）。
- 2FA Secret 与业务条目随加密载荷统一密文落盘。
- 解锁失败保护状态（失败次数、锁定截止时间）存储在 envelope 元信息中，不包含明文账号密码。

## 3. 网络与隐私边界

- 同步链路仅使用用户配置的 HTTPS 端点（WebDAV/S3 预签名 URL）。
- 同步日志已做敏感信息脱敏（password/token/authorization/Bearer）。
- 应用默认不上传遥测或统计数据。

## 4. 发布前核对项

1. 在 DevEco Product 配置中确认 `INTERNET` 权限与发布包一致。
2. 隐私政策中明确：
   - 数据主要本地加密保存；
   - 同步仅在用户显式配置后生效；
   - 不采集与业务无关个人信息。
3. 真机回归时验证：
   - 未授予任何敏感权限时仍可离线使用；
   - 开启同步后网络功能正常；
   - 日志中不出现 token/secret 明文。
