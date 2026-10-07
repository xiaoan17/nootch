# nootch 1.4.0 同步引擎验收

## 范围与版本

本次完成 Kimi 会话中原定的 34 个 usage source：原有 5 个 + 第一轮 5 个 + 后续 24 个；Qoder 与 Qoder CN 分别计为一个来源，Cline 与 Roo Code 分别注册。原会话漏提的 Amp 也已补齐。完整清单由 `VibeSyncEngine.defaultParsers()` 和注册表测试共同约束。

本次对照源码：`vibe-cafe/vibe-usage`，提交 `abb2640f5efd1d17ae1df21b139c4235021c83eb`（2026-10-07，0.14.0）。这不代表移植了整个 0.14.0 CLI：本任务为原定 34 个 usage source 及同步正确性修复，不包括 quota 产品、CLI 管理命令、daemon 或今天新增的 Kiki 来源及其专用历史迁移流程。Kiki 不会被混入 Kimi Code 上传。

保留 macOS 原生 Swift + 系统 SQLite 架构。dsh 的公开 libzstd 运行库放在 App `Contents/Frameworks` 并单独签名，安装后不需要 Node/Homebrew。`packaging/ZSTD-LICENSE` 随 App 分发。

## 已实现

- 引擎：未知来源的 bucket/session 均保留为未提交，之后重试；state identity 绑定 API URL 与 key 指纹；不保存原始 key。
- Claude：缓存写入按 5m / 1h 拆分、Fast mode；Codex continuation 合并；Kimi Work 路径；Grok usage.json 账本。
- 34 来源全部注册。Cursor 与 Antigravity RPC 使用异步请求，失败来源不阻塞其余来源。
- Cursor：仅查询 SQLite 内的 Cursor 登录字段，向固定官方 HTTPS 端点请求 CSV；拒绝重定向以免转发凭证。120 秒导出上限、认证失败回退、非认证失败跳过；表头变化保护同步状态；云端固定 hostname 去重。
- dsh：V0–V4，优先最新文件格式，多帧 Zstandard、skippable frame、截断尾帧恢复、大小上限；有父日志证据才消除分叉历史。
- Cline：旧 history 与 SDK v1；复原副本按消息身份去重并保留最丰富计数；未知 SDK 格式跳过。Roo：索引及逐 task history。
- Kiro：native CLI stream → CLI SQLite/归档 → IDE credit 增量的优先级；legacy telemetry 仅显式开启；签名不算生成 token。
- Antigravity：离线 SQLite/protobuf 优先、timestamp 缺失按 step idx 回填；旧 `.pb` 仅用对应本机 language server，未读出时保留同步状态。
- 单次同步 / dry-run 不再同时启动常规 UI 后台同步任务。
- 真机预演发现发布版混合同步/异步解析器的匿名元组结果会丢失来源归属；现改为命名结果结构体携带来源及编号，并在写状态前断言结果完整性。新增混合类型解析器回归，同时验证 debug 和 release。

## 可复现验证

```sh
sh Tools/test.sh
sh Tools/test.sh -c release
sh Tools/test.sh --filter 'VibeSyncRemainingParserTests|VibeSyncUpstreamParityTests'
# 可选：用指定的上游 checkout 再生成同一组合成输入和官方期望输出
node Tools/generate-vibe-parity.mjs /path/to/vibe-usage
sh packaging/build-app.sh
codesign --verify --strict --verbose=2 dist/nootch.app
sh Tools/install-local.sh  # 安装本地构建，保留 /tmp 下旧版备份
/Applications/nootch.app/Contents/MacOS/nootch --vibe-sync-dry-run
```

`Tests/Fixtures/remaining-parsers/provenance.json` 记录官方期望输出版本。合成样例覆盖 Amp、dsh、Cline、Kiro、Cursor；Swift 与 JS 比较完整 bucket/session 字段（本机 hostname 除外，Cursor 固定 hostname 必须一致）。其他定向测试覆盖 Roo、Cline SDK、Antigravity SQLite/RPC、错误格式和增量状态边界。Fixture 中的 Cursor token 是无效的 `fixture-only`，网络响应由测试注入。

## 对抗式审查重点

1. **有文件却未生效**：注册表断言 34 个来源，禁止重复或遗漏。
2. **同一份历史多次计数**：Cursor cloud hostname、Cline 恢复副本、dsh 父子回放和 Antigravity responseId 均有针对性测试。
3. **读失败被当成空历史**：未知格式/错误网络标为 skipped 或 failed，保留来源的增量状态；上传未知来源不提交 hash。
4. **打包成功但用户不能运行**：校验库依赖、资源、签名，并对安装副本做独立启动及同步检查。
5. **dry-run 有副作用 / 凭证泄漏**：禁止后台同步伴随单次命令启动；Cursor 请求只发官方域名，不跟随重定向，不记录 token 或响应正文。

## 边界

- Kiro 的 CLI token 是字符/图片估算，不能当作供应商账单精确 token；IDE 使用独立 credit 模型。
- 无实际安装/日志的来源仅通过合成测试，不宣称 34 个客户端全部完成真机实测。
- 旧 Antigravity 加密历史需要对应进程运行；Cursor 失效登录需要在 Cursor 内重新登录。
- 后端未注册的 source 会被 soft-drop，客户端自动保留重试；本次不修改 vibecafe.ai 后端。
- 本地 1.4.0 构建不等于 GitHub Release、Homebrew 发布或公证。

## 2026-10-07 验证结果

- debug / release 全量均为 363 个测试、28 个 suite 通过；包含混合类型解析器归属回归。
- 官方 JS 黄金样例：5 个来源完整 bucket/session 字段对照通过。
- 修复后的真实日志预演：34 个来源全部返回成功（缺少本机日志的来源会返回空结果）；3478 个 bucket、2311 个 session，159 个 bucket / 296 个 session 待更新，上传为 0。
- 预演显示 2110 个失效本地增量 key 可清理；这是本地 hash 状态清理，不是删除云端历史。
- libzstd 与 nootch 均为 arm64；库仅依赖 macOS libSystem，无 Homebrew 绝对运行时依赖。
- `/Applications/nootch.app` 已安装 1.4.0（build 12），签名通过，独立启动曾验证。安装二进制 SHA-256：`4538d4accf8e55e96bd91035defa57f272848ec472b31a1203ff6ad4164b344b`，与 `dist/nootch.app` 相同。
- 旧 App 备份：`/tmp/nootch-backup.6bfSU7/nootch.app`。
- 真实上传验收被自动审批拒绝，理由为缺少向配置目的地 `https://vibecafe.ai` 发送真实本地用量/会话元数据的明确授权。没有执行该手动上传命令；App 已暂停，等待用户选择是否验收上传及恢复原有自动同步。
