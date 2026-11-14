# Changelog

Notable changes to Remarc. The [GitHub Releases page](https://github.com/handsomeliuyang/Remarc/releases) is the authoritative list going forward.

## 1.2.39 - 2026-11-14

### 新增

- 新增「暂缓」评论状态，使用玫紫色和暂停图标，自动排在活跃评论之后，并支持筛选及手动恢复待处理。（[提交](https://github.com/handsomeliuyang/JotBaton/commit/e9acb833a56626840756a57af97a5bad655c954e)）

### 优化

- 顶部筛选调整为「待处理、已转交、进行中、暂缓」，已转交独立计数，移除已完成筛选。（[提交](https://github.com/handsomeliuyang/JotBaton/commit/e9acb833a56626840756a57af97a5bad655c954e)）
- 单条与批量启动统一只复制待处理和进行中的评论；待处理转为进行中，已转交、暂缓、已完成均跳过，无可处理评论时禁用启动。（[提交](https://github.com/handsomeliuyang/JotBaton/commit/e9acb833a56626840756a57af97a5bad655c954e)）
- 再次启动进行中的评论保留原状态；完成按钮继续仅处理进行中的评论，普通复制仍保留完整内容。（[提交](https://github.com/handsomeliuyang/JotBaton/commit/e9acb833a56626840756a57af97a5bad655c954e)）

[完整变更](https://github.com/handsomeliuyang/JotBaton/compare/v1.2.38...v1.2.39)

<!-- remarc-release: {"base_tag": "v1.2.38", "build": "58", "source_sha": "e9acb833a56626840756a57af97a5bad655c954e"} -->

## 1.2.38 - 2026-11-13

### 重大变更

- 正式采用 JotBaton 名称与独立图标，应用、菜单栏、Dev 标识及浏览器配套界面统一品牌；保留原有 Bundle ID、签名及本地/iCloud 数据目录。旧 Remarc 版本需手动升级一次，之后使用新版更新流程。安装包文件名暂保留 `Remarc-` 前缀以兼容已有下载入口。([1233b54](https://github.com/handsomeliuyang/JotBaton/commit/1233b54f421c045e899b053568f330a7614e7276))
- 移除内置语音功能及现有 MCP/agent 集成，当前工作流为快速记录、复制给外部 AI 执行、手动标记完成。([badd431](https://github.com/handsomeliuyang/JotBaton/commit/badd43106f2c7bed7845838f487e12622682af69), [36aca55](https://github.com/handsomeliuyang/JotBaton/commit/36aca55837f1abae5aae7f87d7a2bfa5d34a7252))

### 新增与修复

- 正式版支持经 Sparkle 验证的应用内升级：下载并校验原生安装包，备份应用与数据后安装、重启。Dev 保持渠道隔离。([e209a77](https://github.com/handsomeliuyang/JotBaton/commit/e209a77cfe116e27f30b92b7b7fbbad874c30f50))
- 增加速记快捷键，方便随时记录临时想法。([badd431](https://github.com/handsomeliuyang/JotBaton/commit/badd43106f2c7bed7845838f487e12622682af69))
- 取消会话数量限制，并修正浮窗高度。([53e1ef1](https://github.com/handsomeliuyang/JotBaton/commit/53e1ef1ce49e9a0bb096688d09fbe2cee4a6dce3))

### 其他变更

- 发布流程从提交生成更新日志，并在侧栏显示版本信息。([e28548a](https://github.com/handsomeliuyang/JotBaton/commit/e28548ab16e782ba0e36c98a5cece5fba65661f2))
- GitHub 仓库改名为 JotBaton 并解除 fork 关系，保留历史发布资产和发布配置，更新独立维护与发布说明。([ea2134f](https://github.com/handsomeliuyang/JotBaton/commit/ea2134f6ae54d9e29556bc4c8ed304dafe62141f))
- 同步 JotBaton 品牌后的发布保护与 Webhook 测试断言，保持原有仓库保护和签名发布检查。([2b65402](https://github.com/handsomeliuyang/JotBaton/commit/2b6540224e113728ee3c6acca084be3163b81d2a))

[完整变更](https://github.com/handsomeliuyang/JotBaton/compare/v1.2.36...v1.2.38)

<!-- remarc-release: {"base_tag": "v1.2.36", "build": "57", "source_sha": "2b6540224e113728ee3c6acca084be3163b81d2a"} -->

## 1.2.37 - 2026-11-13

### 重大变更

- 正式采用 JotBaton 名称与独立图标，应用、菜单栏、Dev 标识及浏览器配套界面统一品牌；保留原有 Bundle ID、签名及本地/iCloud 数据目录。旧 Remarc 版本需手动升级一次，之后使用新版更新流程。安装包文件名暂保留 `Remarc-` 前缀以兼容已有下载入口。([1233b54](https://github.com/handsomeliuyang/JotBaton/commit/1233b54f421c045e899b053568f330a7614e7276))
- 移除内置语音功能及现有 MCP/agent 集成，当前工作流为快速记录、复制给外部 AI 执行、手动标记完成。([badd431](https://github.com/handsomeliuyang/JotBaton/commit/badd43106f2c7bed7845838f487e12622682af69), [36aca55](https://github.com/handsomeliuyang/JotBaton/commit/36aca55837f1abae5aae7f87d7a2bfa5d34a7252))

### 新增与修复

- 正式版支持经 Sparkle 验证的应用内升级：下载并校验原生安装包，备份应用与数据后安装、重启。Dev 保持渠道隔离。([e209a77](https://github.com/handsomeliuyang/JotBaton/commit/e209a77cfe116e27f30b92b7b7fbbad874c30f50))
- 增加速记快捷键，方便随时记录临时想法。([badd431](https://github.com/handsomeliuyang/JotBaton/commit/badd43106f2c7bed7845838f487e12622682af69))
- 取消会话数量限制，并修正浮窗高度。([53e1ef1](https://github.com/handsomeliuyang/JotBaton/commit/53e1ef1ce49e9a0bb096688d09fbe2cee4a6dce3))

### 其他变更

- 发布流程从提交生成更新日志，并在侧栏显示版本信息。([e28548a](https://github.com/handsomeliuyang/JotBaton/commit/e28548ab16e782ba0e36c98a5cece5fba65661f2))
- GitHub 仓库改名为 JotBaton 并解除 fork 关系，保留历史发布资产和发布配置，更新独立维护与发布说明。([ea2134f](https://github.com/handsomeliuyang/JotBaton/commit/ea2134f6ae54d9e29556bc4c8ed304dafe62141f))

[完整变更](https://github.com/handsomeliuyang/JotBaton/compare/v1.2.36...v1.2.37)

<!-- remarc-release: {"base_tag": "v1.2.36", "build": "56", "source_sha": "ea2134f6ae54d9e29556bc4c8ed304dafe62141f"} -->

## 1.2.30 - 2026-11-12

- Session counts now follow the selected comment status filters, including multiple selections and all statuses when none are selected.
- Comment status changes update each session's count immediately; sessions with zero matching comments remain visible.
- Release artifact downloads explicitly use the current workflow run and authenticated GitHub API access.

## 1.2.29 - 2026-11-11

- Production now checks this repository's GitHub Releases and opens the installer matching the Mac's architecture for manual installation.
- Production builds, both full Swift test profiles and publication run through the manually dispatched GitHub Release workflow. Local builds are Dev only.
- Removes the iCloud software publisher and automatic installer while preserving channel-isolated iCloud data snapshot synchronization.

## 0.5.1 - 2026-08-06

- Fixes an update issue where the previous Claude Code integration could be removed before the new plugin was installed
- More reliable one-click plugin install when the command line prints warnings

## 0.5.0 - 2026-08-06

- Claude Code integration is now a plugin: one-click install from Preferences or onboarding, with automatic cleanup of the old integration
- Webhooks: send comment events (created, resolved, deleted) to any service as HTTP POST
- Compact timestamps on comment cards, loopback-only extension listener, and an updated speech recognition stack

## 0.4.1 - 2026-05-12

- Improvements to web context capture when commenting on web pages
- Improvements to dictation and voice notes
- Bug fixes and polish

## 0.4.0 - 2026-05-08

- Improved MCP integration logic; Remarc now auto-installs a skill for Claude / Codex / Cursor
- Added MCP integration installers for Codex and Cursor
- Improved Chrome/web context capture for comments and screenshots
- Improved dictation reliability and microphone selection; built-in mic is preferred over AirPods unless a better mic is available
- Lots of other quality-of-life improvements

## 0.3.3 - 2026-03-31

- Added Show in Dock preference for window management
- Onboarding and settings windows are now focusable and miniaturizable
- Fixed MCP/hook script paths for release builds
- Fixed tooltip dismissal on activation policy switch
- Improved settings titlebar appearance

## 0.3.2 - 2026-03-27

- Lowered minimum macOS version from 14.4 to 14.0 (Sonoma)

## 0.3.1 - 2026-03-24

- Added Chrome extension information to settings and invite page

## 0.3.0 - 2026-03-24

- New landing page for the Remarc Early Testing program
- Fixed comment and overlay positioning on external displays
- Added tooltip position setting (above or below selection)
- Added Open Remarc and Start Crit Mode global shortcuts
- Added sound effects toggle and improved dictation sound timing
- Fixed tooltip shadow clipping and AX activation fallback

## 0.2.2 - 2026-03-21

- Added mic and screen recording permission checks to onboarding
- Added paste last dictation shortcut (Ctrl-Opt-L)
- Added Claude Desktop setup section and permissions tip in settings
- Improved button contrast in dark mode
- Fixed crash when switching audio input device between recordings
- Fixed push-to-talk keyUp forwarding to comment box
- Changed default shortcuts to use Control+Option

## 0.2.1 - 2026-03-21

- Improved first-run reliability for MCP dependency detection
- Show MCP error state in main window when Node.js or Claude CLI is missing

## 0.2.0 - 2026-03-21

- Added voice input with WhisperKit and Parakeet transcription engines
- Added dictation mode with fn/globe key shortcut support
- Added Claude Code integration with MCP server, hooks, and session management
- Added in-app feedback feature
