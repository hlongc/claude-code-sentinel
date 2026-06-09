# Claude Code Sentinel

中文 | [English](README.en.md)

[![Release](https://img.shields.io/github/v/release/hlongc/claude-code-sentinel)](https://github.com/hlongc/claude-code-sentinel/releases)
[![License](https://img.shields.io/github/license/hlongc/claude-code-sentinel)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-native-black)](#系统要求)
[![Homebrew](https://img.shields.io/badge/Homebrew-hlongc%2Ftap-blue)](#homebrew)

别再守着 Claude Code 终端等确认了。Claude Code Sentinel 会在需要你批准权限、回答多选问题或任务完成时，用原生 macOS 浮窗把你叫回来。

它是 Swift 编译出的命令行二进制，日常使用不依赖 Node.js，也不受当前 `nvm` 版本影响。

```sh
brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed
```

## Demo

> 这里适合放一个 10-20 秒 GIF：Claude Code 请求权限，Sentinel 在右上角弹出审批浮窗，点击 `Yes` 后 Claude Code 继续执行。
>
> 建议文件路径：`assets/demo.gif`，之后可以用 `![Demo](assets/demo.gif)` 嵌入。

## 目录

- [Demo](#demo)
- [为什么需要它](#为什么需要它)
- [功能特性](#功能特性)
- [关键词](#关键词)
- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [安装方式](#安装方式)
- [本地预览](#本地预览)
- [配置方式](#配置方式)
- [OpenCode 支持](#opencode-支持)
- [终端活跃时不打扰](#终端活跃时不打扰)
- [支持范围](#支持范围)
- [维护者文档](#维护者文档)
- [许可证](#许可证)

## 为什么需要它

Claude Code 很适合长时间执行任务，但它经常会停在权限确认、工具调用确认或多选问题上。如果你切去写文档、看网页或处理其他工作，任务可能已经卡住很久，而你完全不知道。

Sentinel 做的事情很简单：它替你盯着 Claude Code。需要你决策时，它弹一个轻量浮窗；你做出选择后，结果会通过 Claude Code hooks 直接返回给当前会话。

## 功能特性

- 原生 macOS 浮动审批窗口，支持 `PermissionRequest`
- 在浮窗中直接选择 `Yes`、`Yes, don't ask again` 或 `No`，并把决策返回给 Claude Code
- 支持 `AskUserQuestion`，按问题逐个展示选项，并可为“补充信息/讨论/其他”等选项追加文字说明
- 支持 OpenCode 权限审批、问题回答和任务通知
- 任务完成和失败通知
- 标题包含项目和 session 信息，方便同时运行多个 Claude Code 任务
- 浮窗可拖拽移动，固定宽度，长内容自动换行
- 终端活跃时不打扰：如果你正在操作 Claude 终端，Sentinel 会保持安静
- 支持安装到 Claude Code managed settings，避免 `cc switch` 等工具重写 `~/.claude/settings.json` 后丢失 hooks

## 关键词

`claude-code` · `claude-code-hooks` · `opencode` · `macos` · `homebrew` · `developer-tools` · `ai-coding` · `notifications`

## 系统要求

- macOS
- Xcode Command Line Tools，需包含 `swiftc`（仅源码编译时需要）
- 支持 hooks 的 Claude Code

## 快速开始

使用 Homebrew：

```sh
brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed
# 可选：同时启用 OpenCode 支持
claude-code-sentinel install-opencode
```

或使用一行安装脚本。发布二进制存在时会直接下载二进制；否则会回退到源码编译：

```sh
curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh | bash
```

然后正常使用 Claude Code：

```sh
claude
```

当 Claude Code 请求权限或提出多选问题时，Sentinel 会在右上角显示浮窗。你的选择会通过 hook response 返回给 Claude Code，因此在受支持的 hook 事件里，你不需要切回终端操作。

默认会把二进制安装到 `~/.local/bin/claude-code-sentinel`。如果 `~/.local/bin` 不在你的 `PATH` 中，安装脚本会给出提示。

如果你想安装到其他位置：

```sh
PREFIX=/usr/local bash -c "$(curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh)"
```

## 安装方式

### Homebrew

```sh
brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed
# 可选：同时启用 OpenCode 支持
claude-code-sentinel install-opencode
```

升级：

```sh
brew update
brew upgrade claude-code-sentinel
```

### 使用 Release 二进制

默认安装脚本会下载 latest release：

```sh
curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh | bash
```

指定版本：

```sh
CLAUDE_SENTINEL_VERSION=v0.1.2 bash -c "$(curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh)"
```

### 从源码安装

```sh
git clone git@github.com:hlongc/claude-code-sentinel.git
cd claude-code-sentinel
make test
make install
```

强制一键脚本从源码编译：

```sh
CLAUDE_SENTINEL_BUILD_FROM_SOURCE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh)"
```

## 本地预览

```sh
make sample-permission
make sample-stop
```

`sample-permission` 会打开审批浮窗，`sample-stop` 会发送完成通知。

## 配置方式

### Managed Settings

推荐使用：

```sh
make install-managed
```

它会写入：

```text
/Library/Application Support/ClaudeCode/managed-settings.json
```

安装脚本会保留已有的顶层 managed settings，只替换 `hooks` 配置块。如果其他工具会重写 `~/.claude/settings.json`，这种方式更稳。

卸载 managed hooks：

```sh
make uninstall-managed
```

检查当前二进制和 managed hooks 配置：

```sh
make doctor
```

### User Settings

如果你更想自己管理 Claude Code 配置：

```sh
make settings
```

把输出里的 `hooks` 对象添加到 `~/.claude/settings.json`。

## OpenCode 支持

同一个 `claude-code-sentinel` 二进制可以同时支持 Claude Code 和 OpenCode。Homebrew 或安装脚本只负责安装二进制；是否启用某个工具，取决于你是否执行对应的配置命令：

```sh
claude-code-sentinel install-managed   # 启用 Claude Code hooks
claude-code-sentinel install-opencode  # 启用 OpenCode plugin
```

两个命令都执行后，Claude Code 和 OpenCode 会同时接入 Sentinel。

`install-opencode` 会安装一个轻量插件到 `~/.config/opencode/plugins/claude-code-sentinel.js`，并在 `~/.config/opencode/opencode.json` 中保留已有配置，只补齐 `permission.edit` 和 `permission.bash` 的 `ask` 设置。

安装或更新 OpenCode 插件：

```sh
make install-opencode
```

如果使用 Homebrew 安装：

```sh
claude-code-sentinel install-opencode
```

检查 OpenCode 配置：

```sh
make doctor-opencode
```

卸载插件：

```sh
make uninstall-opencode
```

OpenCode 支持范围：

- 权限请求：显示 `No`、`Yes`、`Yes, always`
- `question.asked`：在浮窗中选择答案并回填到 OpenCode；遇到“补充信息/讨论/其他”等选项时会继续弹出文本输入框
- `session.idle` 和 `session.error`：发送完成或失败通知

如果权限 payload 中包含很长的 diff，Sentinel 会提取文件名和增删摘要，避免把完整 JSON 或完整 diff 塞进弹窗。

OpenCode 插件需要重新启动 OpenCode 会话后才会加载最新安装的插件文件。

## 终端活跃时不打扰

如果当前前台窗口看起来是同一个 Claude Code 终端，并且 macOS 最近收到过键盘或鼠标输入，Sentinel 会静默，让终端原生 UI 处理这个提示。

如果系统空闲超过 8 秒，或者当前前台是其他 app，Sentinel 会显示桌面浮窗。若 hook 触发瞬间你刚好还在 Claude 终端，Sentinel 会继续观察最多 15 秒；期间一旦你离开终端或系统进入空闲，就会补弹提醒。

Claude Code 有时会在 `Stop` 后约 60 秒发送 `idle_prompt`，表示会话正在等待你继续输入。Sentinel 默认会抑制同一会话在 `Stop` 后 90 秒内的这类空闲提醒，避免刚收到完成通知又收到“等待输入”的重复提醒。

可以在启动 `claude` 的环境中调整空闲阈值和观察时间：

```sh
export CLAUDE_SENTINEL_ACTIVE_IDLE_SECONDS=10
export CLAUDE_SENTINEL_ACTIVE_GRACE_SECONDS=20
export CLAUDE_SENTINEL_IDLE_AFTER_STOP_SECONDS=90
claude
```

调试日志写在：

```text
~/Library/Logs/ClaudeCodeSentinel/hooks.log
```

## 支持范围

Sentinel 基于 Claude Code hooks 工作，因此它能处理 Claude Code 通过 hook 系统暴露的事件：

- `PermissionRequest`
- `PreToolUse` 中的 `AskUserQuestion`
- `Notification`
- `Stop`
- `StopFailure`

OpenCode 集成通过 OpenCode 插件事件处理权限、问题和会话通知。

它不会监听已经运行中的 shell 命令内部交互提示。例如 Claude Code 或 OpenCode 启动某个 CLI 后，该 CLI 自己询问 `Continue? [y/N]`，这种情况需要额外的 PTY 包装层。

## 维护者文档

本地开发、发版和 Homebrew tap 自动化请看 [Maintainer Guide](docs/maintainer.md)。

## 许可证

MIT
