# 加密兼容性回归清单（Flutter 旧数据 -> Harmony 解密 -> 再同步）

更新时间：2026-03-01

## 1. 目标

验证以下链路在 Harmony 端切换 `CryptoArchitectureKit` 后是否成立：

1. Flutter 历史数据可被 Harmony 端读取（解密/展示）。
2. Harmony 写回同步后，Flutter 端仍可读取（无数据损坏）。
3. 同步过程不泄露明文敏感信息（日志脱敏有效）。

## 2. 前置条件

- Flutter 与 Harmony 使用同一远端同步目标（WebDAV 或 S3 预签名 URL）。
- Flutter 端已有真实历史数据（非全新空库）。
- Harmony 端使用当前分支版本（已切换 `CryptoArchitectureKit`）。
- 已准备真机与日志抓取能力（`hdc shell hilog`）。

执行信息记录：

- Flutter 提交号：
- Harmony 提交号：
- 测试日期：
- 设备信息（Flutter / Harmony）：
- 同步方式（WebDAV/S3）：

## 3. 测试数据基线（先在 Flutter 端确认）

> 目的：后续在 Harmony 与回写后对比一致性。

请先记录下列基线：

- 总条目数：
- credential 条目数：
- server 条目数：
- service 条目数：
- 标签总数：
- 已删除条目数（如有）：
- 抽样条目 A（ID/标题/更新时间）：
- 抽样条目 B（ID/标题/更新时间）：
- 抽样条目 C（ID/标题/更新时间）：

建议在 Flutter 端额外导出一份密文快照留存（用于问题追查）。

## 4. 安全防护（必须先做）

> 当前跨端同步结构可能存在差异，先备份远端，避免误覆盖。

1. 下载远端 `vault.json`（或等价同步对象）到本地备份。
2. 记录备份文件名与 SHA256：

```bash
shasum -a 256 <backup-file>
```

3. 仅在备份完成后再执行 Harmony 同步用例。

## 5. 回归用例矩阵

| 用例ID | 场景 | 操作步骤 | 期望结果 | 实际结果 | 结论 |
|---|---|---|---|---|---|
| C-01 | Flutter 基线确认 | Flutter 解锁并核对第3节基线数据；执行一次同步 | 同步成功，基线数据稳定 |  | 通过/失败 |
| C-02 | Harmony 首次解锁 | Harmony 初始化/解锁（主密码与 Flutter 一致） | 可正常进入列表页，不崩溃 |  | 通过/失败 |
| C-03 | Harmony 拉取 Flutter 历史数据 | 在 Harmony 点击“立即同步”一次 | Harmony 端出现与 Flutter 基线一致的数据（数量与抽样一致） |  | 通过/失败/阻断 |
| C-04 | Harmony 重启复验 | Harmony 锁定、杀进程、重启后再解锁 | C-03 数据仍可解锁查看 |  | 通过/失败 |
| C-05 | Harmony 增量修改并上行 | Harmony 新增1条记录 + 修改1条记录 + 新增1标签，再同步 | 同步成功，修订号递增，日志无明文敏感字段 |  | 通过/失败 |
| C-06 | Flutter 回拉验证 | Flutter 执行同步并核对变更 | 能看到 C-05 的新增/修改，且旧数据未丢失 |  | 通过/失败/阻断 |
| C-07 | 双端重复解锁验证 | Flutter/Harmony 各自重启并解锁 | 两端均可正常解锁，关键抽样条目内容一致 |  | 通过/失败 |

## 6. 日志与证据采集

建议每个关键步骤采集以下证据：

- Harmony 日志（建议按时间段截取）：

```bash
hdc shell hilog | grep -E "Vault|sync|encrypt|decrypt|CryptoArchitectureKit"
```

- Flutter 日志（IDE 控制台导出）。
- 远端对象变更前后文件（至少保存 C-03 前、C-05 后、C-06 后三个版本）。

脱敏检查点（至少人工核对一次）：

- 日志中不应出现明文 `password=` / `token=` / `authorization=` / `Bearer <token>`。

## 7. 失败判定与回滚

任一情况视为阻断：

1. Harmony 同步后条目明显减少/清空。
2. Flutter 回拉后无法解锁或出现大规模解密失败。
3. 两端任一端出现不可恢复的数据结构错误。

阻断时立即执行：

1. 停止继续同步操作。
2. 将远端对象回滚为第4节备份版本。
3. 记录阻断点用例ID、设备、时间与日志片段。

## 8. 验收结论

- [ ] 全部用例通过，可判定“Flutter 旧数据 <-> Harmony(Kit)”兼容可用。
- [ ] 存在失败用例，需修复后复测。

问题清单：

1. 
2. 
3. 
