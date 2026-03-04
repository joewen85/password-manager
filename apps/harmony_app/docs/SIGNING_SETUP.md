# HarmonyOS 6 签名产物生成指南

更新时间：2026-03-01

## 1. 目标

在当前项目中生成可安装的 signed HAP（替代 `entry-default-unsigned.hap`）。

## 2. 前置材料

需要准备以下签名材料（通常由 DevEco 签名向导或团队证书体系提供）：

- `storeFile`：签名库文件（如 `.p12`）
- `profile`：Profile 文件
- `certpath`：证书链文件
- `storePassword`
- `keyAlias`
- `keyPassword`

## 3. 命令行签名构建

推荐方式（一次配置，后续直接执行）：

```bash
./scripts/harmony_build_signed_hap.sh
```

首次执行会自动生成 `apps/harmony_app/signing/signing.env` 模板并退出。
然后编辑该文件，填入真实签名材料路径与密码。

执行：

```bash
./scripts/harmony_build_signed_hap.sh
```

可选方式（使用自定义 env 文件）：

```bash
./scripts/harmony_build_signed_hap.sh --env-file /absolute/path/to/signing.env
```

说明：
- 该脚本会临时写入签名配置到 `apps/harmony_app/build-profile.json5`，构建结束后自动恢复原文件。
- 内部调用 `./scripts/harmony_build_hap.sh default` 完成打包。

## 4. 产物检查

构建日志会打印产物路径，常见输出目录：

`apps/harmony_app/entry/build/default/outputs/default/`

若签名成功，目录中应出现 `signed` 命名的 HAP。

## 5. 安装验证

```bash
./scripts/harmony_install_hap.sh <signed_hap路径> com.example.passwordmanager
```

再按 `DEVECO_BUILD_AND_DEVICE_VALIDATION.md` 的真机冒烟清单执行并回填结果。
