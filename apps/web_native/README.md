# Password Manager Web Native

## 中文

该目录包含 Web 原生重构目标。它与 `apps/flutter_app` 明确隔离，用于在不改动现有 Flutter Web 实现和既有功能行为的前提下，逐步补齐浏览器原生端能力。

### 范围

- 使用浏览器原生平台能力实现：HTML、CSS、ES Modules、Web Crypto、LocalStorage、File API、PWA manifest 和 Service Worker。
- 当前切片支持初始化/解锁本地加密 vault、credential/server/service 条目 CRUD、搜索、分类/标签集合、TOTP 解锁、JSON 导入导出、本地备份、恢复最新备份、同步设置保存、手动同步和静态资源离线缓存。
- 本地加密使用 PBKDF2-SHA256 和 AES-256-GCM，默认迭代次数为 600000。
- Web Crypto envelope 形状与其他原生端保持一致：`masterKeyRecord` + `encryptedVault`。
- 同步设置支持 WebDAV、NAS WebDAV、S3 presigned URL 字段，并将敏感字段从普通配置中 redacted。
- 手动同步支持 WebDAV/NAS WebDAV GET + PUT、S3 presigned URL GET + PUT、远端缺失时上传本地 payload、远端存在时进行 version-vector merge 后按需上传新 revision。
- 真实 WebDAV/S3 服务的浏览器端到端验证仍需在生产候选环境完成。

### 目录说明

- `index.html`: 原生 Web app UI。
- `styles.css`: 响应式应用样式。
- `manifest.webmanifest`: PWA manifest。
- `assets/icon.svg`: PWA 图标。
- `sw.js`: PWA 静态资源离线缓存 Service Worker。
- `src/vault-core.mjs`: 可测试核心逻辑。
- `src/app.mjs`: DOM UI、LocalStorage 持久化和用户交互。
- `test/vault-core.test.mjs`: Node 测试。
- `tools/serve.mjs`: 本地静态文件服务器。

### 环境要求

- Node.js 20 或更高版本。
- 现代浏览器，需支持 Web Crypto、ES Modules、`dialog`、File API 和 LocalStorage。

### 开发

运行测试：

```bash
npm test
```

启动本地静态服务器：

```bash
npm run serve
```

默认地址：

```text
http://localhost:4173
```

也可以直接打开 `index.html`，但本地服务器更接近部署环境。

### 本地功能验证

1. 创建 vault，确认 `localStorage` 中保存的是 encrypted envelope。
2. 新增 credential、server、service 条目。
3. 搜索条目，检查分类和标签集合。
4. 锁定后用正确密码解锁，错误密码应失败。
5. 在 Settings 中启用 TOTP，并用当前验证码验证解锁。
6. 导出 JSON，再通过 Import JSON 导入。
7. 执行 Backup 和 Restore Latest。
8. 配置 WebDAV 或 S3 presigned URL，执行手动同步，应显示成功或明确的 HTTP 错误状态。
9. 安装或刷新 PWA，确认 `sw.js` 注册成功且静态资源可离线命中。
10. 检查普通同步设置不包含 `webdavPassword`、presigned download URL 或 presigned upload URL 明文。

自动测试覆盖：

- PBKDF2/AES-GCM envelope 往返和明文泄露检查。
- 错误密码拒绝。
- TOTP RFC 6238 SHA1 fixture。
- 条目过滤、软删除、集合重建和备份命名。
- 同步设置 redaction/apply-secrets。
- version-vector dominance 和并发冲突合并。
- WebDAV URL 规范化、Basic Auth、S3 presigned download/upload。
- 远端缺失上传本地 payload，远端存在时 merge 并上传新 revision。

### 发布构建

当前实现是静态 Web/PWA，无需构建步骤。发布前执行：

```bash
npm test
```

准备静态目录：

```text
apps/web_native/index.html
apps/web_native/styles.css
apps/web_native/manifest.webmanifest
apps/web_native/sw.js
apps/web_native/assets/
apps/web_native/src/
```

部署到静态托管时需要：

1. 使用 HTTPS。
2. 设置 `index.html`、`.mjs`、`.css`、`.webmanifest`、`.svg` 的正确 MIME type。
3. 设置缓存策略，HTML 使用短缓存，静态资源可使用较长缓存。
4. 如果启用 PWA 安装，确保 manifest、icon 和 `sw.js` 可访问。
5. 不要把测试、临时文件或本地 secret 上传到公开站点。

### 上架 / 分发

Web 原生端通常通过 HTTPS 站点和 PWA 分发：

1. 选择托管平台，例如 Nginx、Cloudflare Pages、Netlify、Vercel、S3 + CDN 或公司自有静态托管。
2. 配置自定义域名和 TLS 证书。
3. 部署静态文件。
4. 使用浏览器检查 manifest、图标、Service Worker 离线缓存、安装能力和控制台错误。
5. 在 Chrome/Edge/Safari/Firefox 验证初始化、解锁、CRUD、导入导出、备份和设置。
6. 对需要企业分发的场景，将 URL 纳入企业门户、MDM web clip 或内部应用目录。
7. 发布说明可以描述 WebDAV/S3 presigned 同步实现和自动测试覆盖；真实服务兼容性只在完成端到端验证后列为已验证能力。

### 发布检查清单

- [x] Web 原生目录在 `apps/web_native` 下创建。
- [x] README 提供中文和英文版本。
- [x] README 说明开发、发布构建、部署和分发步骤。
- [x] 本地 vault envelope 使用 PBKDF2-SHA256 + AES-256-GCM。
- [x] 测试覆盖加密往返、TOTP、条目过滤/备份、同步设置 redaction 和 merge。
- [x] UI 支持初始化/解锁、CRUD、搜索、导入导出、备份、恢复、Settings 和手动同步。
- [x] WebDAV/S3 presigned 远端同步上传下载实现并通过 mock 测试。
- [ ] 真实 WebDAV/S3 服务浏览器端到端验证完成。
- [x] PWA service worker / offline cache 策略完成。
- [ ] 浏览器兼容性矩阵完成：Chrome、Edge、Safari、Firefox。
- [ ] HTTPS 生产托管和 PWA 安装验证完成。
- [ ] Web 安全审查完成：CSP、依赖、XSS、LocalStorage 风险说明和备份策略。

---

## English

This directory contains the native Web rewrite target. It is intentionally separate from `apps/flutter_app` so the existing Flutter Web implementation remains untouched while browser-native parity is built incrementally.

### Scope

- Uses native browser platform capabilities: HTML, CSS, ES Modules, Web Crypto, LocalStorage, File API, a PWA manifest, and a service worker.
- The current slice supports local encrypted vault setup/unlock, credential/server/service CRUD, search, category/tag collections, TOTP unlock, JSON import/export, local backup, latest-backup restore, sync settings persistence, manual sync, and static-asset offline caching.
- Local encryption uses PBKDF2-SHA256 and AES-256-GCM with a default iteration count of 600000.
- The Web Crypto envelope shape matches the other native targets: `masterKeyRecord` plus `encryptedVault`.
- Sync settings support WebDAV, NAS WebDAV, and S3 presigned URL fields, with sensitive fields redacted from normal settings.
- Manual sync supports WebDAV/NAS WebDAV GET + PUT, S3 presigned URL GET + PUT, local payload upload when the remote vault is missing, and version-vector merge followed by a new revision upload when needed.
- Real browser end-to-end validation against live WebDAV/S3 services still needs to be completed in a release-candidate environment.

### Directory Layout

- `index.html`: native Web app UI.
- `styles.css`: responsive app styling.
- `manifest.webmanifest`: PWA manifest.
- `assets/icon.svg`: PWA icon.
- `sw.js`: PWA static-asset offline-cache service worker.
- `src/vault-core.mjs`: testable core logic.
- `src/app.mjs`: DOM UI, LocalStorage persistence, and user interactions.
- `test/vault-core.test.mjs`: Node tests.
- `tools/serve.mjs`: local static file server.

### Requirements

- Node.js 20 or later.
- Modern browser with Web Crypto, ES Modules, `dialog`, File API, and LocalStorage support.

### Develop

Run tests:

```bash
npm test
```

Start the local static server:

```bash
npm run serve
```

Default URL:

```text
http://localhost:4173
```

Opening `index.html` directly also works, but the local server is closer to deployment.

### Local Feature Verification

1. Create a vault and confirm LocalStorage stores an encrypted envelope.
2. Add credential, server, and service entries.
3. Search entries and inspect category/tag collections.
4. Lock and unlock with the correct password; wrong passwords should fail.
5. Enable TOTP in Settings and unlock with the current authenticator code.
6. Export JSON, then import through Import JSON.
7. Run Backup and Restore Latest.
8. Configure WebDAV or S3 presigned URL and run manual sync; sync status should show success or a clear HTTP error status.
9. Install or refresh the PWA and confirm `sw.js` registers and static assets are available from the offline cache.
10. Confirm normal sync settings do not contain plaintext `webdavPassword`, presigned download URL, or presigned upload URL.

Automated tests cover:

- PBKDF2/AES-GCM envelope round trip and plaintext leakage checks.
- Wrong-password rejection.
- TOTP RFC 6238 SHA1 fixture.
- Entry filtering, soft delete, collection rebuilding, and backup naming.
- Sync settings redaction/apply-secrets.
- Version-vector dominance and concurrent conflict merge.
- WebDAV URL normalization, Basic Auth, and S3 presigned download/upload.
- Missing-remote local payload upload, and remote-present merge with new revision upload.

### Release Build

This is a static Web/PWA implementation and currently has no build step. Before release, run:

```bash
npm test
```

Prepare these static files:

```text
apps/web_native/index.html
apps/web_native/styles.css
apps/web_native/manifest.webmanifest
apps/web_native/sw.js
apps/web_native/assets/
apps/web_native/src/
```

Static hosting requirements:

1. Use HTTPS.
2. Serve `index.html`, `.mjs`, `.css`, `.webmanifest`, and `.svg` with correct MIME types.
3. Configure caching: short cache for HTML, longer cache for static assets.
4. If PWA install is enabled, ensure the manifest, icon, and `sw.js` are reachable.
5. Do not publish tests, temporary files, or local secrets to the public site.

### Submission / Distribution

The native Web target is usually distributed as an HTTPS site and PWA:

1. Choose hosting, such as Nginx, Cloudflare Pages, Netlify, Vercel, S3 + CDN, or internal static hosting.
2. Configure custom domain and TLS certificate.
3. Deploy static files.
4. Inspect manifest, icons, service-worker offline cache, installability, and console errors in the browser.
5. Verify setup, unlock, CRUD, import/export, backup, and settings in Chrome/Edge/Safari/Firefox.
6. For enterprise distribution, add the URL to the company portal, MDM web clip, or internal app catalog.
7. Release notes may describe the WebDAV/S3 presigned sync implementation and automated test coverage; only list live-service compatibility as verified after end-to-end validation.

### Release Checklist

- [x] Native Web directory is created under `apps/web_native`.
- [x] README provides Chinese and English versions.
- [x] README documents development, release build, deployment, and distribution steps.
- [x] Local vault envelope uses PBKDF2-SHA256 + AES-256-GCM.
- [x] Tests cover crypto round trip, TOTP, entry filtering/backup, sync settings redaction, and merge.
- [x] UI supports setup/unlock, CRUD, search, import/export, backup, restore, Settings, and manual sync.
- [x] WebDAV/S3 presigned remote sync upload/download is implemented and covered by mock tests.
- [ ] Real WebDAV/S3 service browser end-to-end validation is complete.
- [x] PWA service worker / offline cache strategy is complete.
- [ ] Browser compatibility matrix is complete: Chrome, Edge, Safari, Firefox.
- [ ] HTTPS production hosting and PWA install validation are complete.
- [ ] Web security review is complete: CSP, dependencies, XSS, LocalStorage risk notes, and backup strategy.
