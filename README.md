# nootch · Vibe Usage 版

> 在 Mac 屏幕边缘常驻一个小圆点，随时告诉你：**今天的 AI 编码用量** —— 花了多少钱、用了多少 token、跑了几个 session、哪些模型用得最多。

![platform](https://img.shields.io/badge/macOS%2015%2B-Apple%20Silicon-black)

## 二次开发声明

本项目是 [DeepanshuMishraa/nootch](https://github.com/DeepanshuMishraa/nootch) 的**二次开发版本（fork）**，感谢原作者 DeepanshuMishraa 开源了这样一个优雅的小工具 —— 全部的 UI 框架（边缘悬浮面板、液态玻璃主题、悬停详情卡、设置窗口）都来自原项目。

数据来源基于 [vibe-cafe/vibe-usage](https://github.com/vibe-cafe/vibe-usage)（[vibecafe.ai](https://vibecafe.ai)），感谢 VibeCafé 团队提供的用量统计服务和开放 API。

### 与原版有什么区别

| | 原版 nootch | 本 fork |
|---|---|---|
| 数据源 | 11 个 AI provider 的订阅配额窗口 | 只保留 **Vibe Usage** 一个数据源 |
| 展示内容 | 各家配额剩余百分比 | **今日用量**：费用 / tokens / sessions / 活跃时长 / Top 模型 |
| 凭证读取 | 读 macOS 钥匙串（会弹密码授权框） | 只读 `~/.vibe-usage/config.json`，**零钥匙串访问、零弹窗** |
| 网络请求 | 轮询各家配额 API | 每 30 秒一次 `GET vibecafe.ai/api/usage?days=1` |

## 工作原理

```
你的 AI 工具日志 (Claude Code / Codex / Kimi Code / ...)
        │  vibe-usage CLI 或 Mac App 本地解析并上传
        ▼
   vibecafe.ai 云端聚合
        │  nootch 每 30s 读取 (Bearer token, 只读)
        ▼
   屏幕边缘的今日用量圆点 + 悬停详情
```

nootch 本身**不解析任何本地日志、不上传任何数据**，只从 vibecafe.ai 读取已聚合的今日用量。

## 安装

要求：Apple Silicon Mac，macOS 15 Sequoia 或更新。

**第一步：配置 vibe-usage**（只需一次）

```sh
npx @vibe-cafe/vibe-usage
```

按提示在浏览器完成授权即可，它会把 API key 写入 `~/.vibe-usage/config.json`。

**第二步：安装 nootch**

从 [Releases](https://github.com/xiaoan17/nootch/releases/latest) 下载 DMG，拖入「应用程序」。

首次打开如果被 Gatekeeper 拦截（本应用为 ad-hoc 签名、未公证），执行：

```sh
xattr -dr com.apple.quarantine /Applications/nootch.app
open -a nootch
```

也可以用 Homebrew：

```sh
brew tap xiaoan17/nootch https://github.com/xiaoan17/nootch
brew install --cask xiaoan17/nootch/nootch
```

## 使用

- 把鼠标移到**屏幕右缘 / 左缘**（可在设置里改到底部居中），面板就会滑出
- 圆点上直接显示**今日费用**（如 `$82.2`）
- **悬停圆点**展开详情卡：总费用、总 tokens、session 数、活跃时长、Top 5 模型费用明细
- 设置窗口里可调整位置、外观、主题色等

### 保持数据新鲜

nootch 显示的是云端数据，本地日志需要持续同步到 vibecafe.ai 才会更新。二选一：

```sh
# 方式一：轻量后台 daemon（推荐，无界面，每 30 分钟同步）
npx @vibe-cafe/vibe-usage daemon install

# 方式二：保持 Vibe Usage Mac App 运行
```

## 从源码构建

需要 Xcode Command Line Tools 和 Swift 6：

```sh
git clone https://github.com/xiaoan17/nootch.git
cd nootch
swift run nootch          # 直接运行
swift test                # 跑测试
packaging/build-app.sh    # 打出 .app 和 DMG（在 dist/）
```

## 致谢 / References

- [DeepanshuMishraa/nootch](https://github.com/DeepanshuMishraa/nootch) — 原项目，全部 UI 与面板框架
- [vibe-cafe/vibe-usage](https://github.com/vibe-cafe/vibe-usage) — 用量数据解析、同步与 API
- [vibecafe.ai](https://vibecafe.ai) — 用量看板与数据服务

---

## English

A derivative fork of [nootch](https://github.com/DeepanshuMishraa/nootch) (all UI credit goes to the original author) that drops every provider integration except one: it shows **today's AI coding usage** from [vibecafe.ai](https://vibecafe.ai) — cost, tokens, sessions, active time, and top models — in the same lovely always-on-top screen-edge overlay. This fork never touches the macOS Keychain (no password prompts); it only reads `~/.vibe-usage/config.json` and calls the read-only usage API every 30 seconds. Run `npx @vibe-cafe/vibe-usage` once to set up the data source, then install the DMG from Releases.
