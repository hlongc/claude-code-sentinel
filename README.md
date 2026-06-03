# Claude Code Sentinel

中文 | [English](README.en.md)

一个原生 macOS Claude Code 审批浮窗。Sentinel 会监听 Claude Code hooks，把权限确认和多选问题带到轻量桌面浮窗里，并在任务完成时提醒你。

它是 Swift 编译出的命令行二进制，日常使用不依赖 Node.js，也不受当前 `nvm` 版本影响。

## 目录

- [功能特性](#功能特性)
- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [安装方式](#安装方式)
- [本地预览](#本地预览)
- [配置方式](#配置方式)
- [终端活跃时不打扰](#终端活跃时不打扰)
- [支持范围](#支持范围)
- [开发](#开发)
- [许可证](#许可证)

## 功能特性

- 原生 macOS 浮动审批窗口，支持 `PermissionRequest`
- 在浮窗中直接选择 `Yes`、`Yes, don't ask again` 或 `No`，并把决策返回给 Claude Code
- 支持 `AskUserQuestion`，按问题逐个展示选项
- 任务完成和失败通知
- 标题包含项目和 session 信息，方便同时运行多个 Claude Code 任务
- 浮窗可拖拽移动，固定宽度，长内容自动换行
- 终端活跃时不打扰：如果你正在操作 Claude 终端，Sentinel 会保持安静
- 支持安装到 Claude Code managed settings，避免 `cc switch` 等工具重写 `~/.claude/settings.json` 后丢失 hooks

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
CLAUDE_SENTINEL_VERSION=v0.1.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh)"
```

### 源码安装

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

## 终端活跃时不打扰

如果当前前台窗口看起来是同一个 Claude Code 终端，并且 macOS 最近收到过键盘或鼠标输入，Sentinel 会静默，让终端原生 UI 处理这个提示。

如果系统空闲超过 20 秒，或者当前前台是其他 app，Sentinel 会显示桌面浮窗。

可以在启动 `claude` 的环境中调整空闲阈值：

```sh
export CLAUDE_SENTINEL_ACTIVE_IDLE_SECONDS=30
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

它不会监听已经运行中的 shell 命令内部交互提示。例如 Claude Code 启动某个 CLI 后，该 CLI 自己询问 `Continue? [y/N]`，这种情况需要额外的 PTY 包装层。

## 开发

```sh
make build
make test
```

二进制会输出到：

```text
release/claude-code-sentinel
```

生成的二进制不会提交到 git。

创建 GitHub Release：

```sh
git tag v0.1.0
git push origin v0.1.0
```

推送 `v*` tag 后，GitHub Actions 会构建 macOS universal binary，并上传到 GitHub Release。

## 许可证

MIT
