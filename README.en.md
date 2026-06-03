# Claude Code Sentinel

[中文](README.md) | English

[![Release](https://img.shields.io/github/v/release/hlongc/claude-code-sentinel)](https://github.com/hlongc/claude-code-sentinel/releases)
[![License](https://img.shields.io/github/license/hlongc/claude-code-sentinel)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-native-black)](#requirements)
[![Homebrew](https://img.shields.io/badge/Homebrew-hlongc%2Ftap-blue)](#homebrew)

Stop babysitting Claude Code. Claude Code Sentinel brings permission approvals, multiple-choice prompts, and completion notifications to a native macOS popover.

It is built as a Swift command line binary, so normal use does not depend on Node.js or the active `nvm` version.

```sh
brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed
```

## Demo

> This is a good place for a 10-20 second GIF: Claude Code asks for permission, Sentinel shows an approval popover in the upper-right corner, and clicking `Yes` lets Claude Code continue.
>
> Suggested path: `assets/demo.gif`, then embed it with `![Demo](assets/demo.gif)`.

## Contents

- [Demo](#demo)
- [Why](#why)
- [Features](#features)
- [Keywords](#keywords)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Installation Options](#installation-options)
- [Try It Locally](#try-it-locally)
- [Configuration](#configuration)
- [Active Terminal Suppression](#active-terminal-suppression)
- [What It Handles](#what-it-handles)
- [Maintainer Guide](#maintainer-guide)
- [License](#license)

## Why

Claude Code is great for long-running tasks, but it often stops for permission approvals, tool-use confirmations, or multiple-choice questions. If you have switched to another app, the task can sit blocked for a long time without you noticing.

Sentinel watches those Claude Code hook events for you. When a decision is needed, it shows a lightweight macOS popover; after you choose, the result is returned directly to the Claude Code session through hooks.

## Features

- Native macOS floating approval popover for `PermissionRequest`
- `Yes`, `Yes, don't ask again`, and `No` actions that return decisions directly to Claude Code
- `AskUserQuestion` support with one question shown at a time
- Task completion and failure notifications
- Session-aware titles for multiple Claude Code terminals
- Drag-to-move popovers with fixed-width wrapping content
- Active-terminal suppression: if you are actively using the Claude terminal, Sentinel stays quiet
- Managed settings installer so tools that rewrite `~/.claude/settings.json` do not remove the hooks

## Keywords

`claude-code` · `claude-code-hooks` · `macos` · `homebrew` · `developer-tools` · `ai-coding` · `notifications`

## Requirements

- macOS
- Xcode Command Line Tools with `swiftc` (only required when building from source)
- Claude Code with hooks support

## Quick Start

Using Homebrew:

```sh
brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed
```

Or use the one-line install script. When a release binary exists, the installer downloads it directly; otherwise it falls back to a source build:

```sh
curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh | bash
```

Then use Claude Code normally:

```sh
claude
```

When Claude Code asks for permission or asks a multiple-choice question, Sentinel can show a popover in the upper-right corner. The selected answer is returned through the hook response, so you do not need to switch back to the terminal for supported hook events.

By default, the binary is installed to `~/.local/bin/claude-code-sentinel`. If `~/.local/bin` is not in your `PATH`, the installer prints a note.

Install somewhere else:

```sh
PREFIX=/usr/local bash -c "$(curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh)"
```

## Installation Options

### Homebrew

```sh
brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed
```

Upgrade:

```sh
brew update
brew upgrade claude-code-sentinel
```

### Release Binary

By default, the installer downloads the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh | bash
```

Install a specific version:

```sh
CLAUDE_SENTINEL_VERSION=v0.1.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh)"
```

### Install From Source

```sh
git clone git@github.com:hlongc/claude-code-sentinel.git
cd claude-code-sentinel
make test
make install
```

Force the one-line installer to build from source:

```sh
CLAUDE_SENTINEL_BUILD_FROM_SOURCE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh)"
```

## Try It Locally

```sh
make sample-permission
make sample-stop
```

`sample-permission` opens the approval popover. `sample-stop` sends a completion notification.

## Configuration

### Managed Settings

Recommended:

```sh
make install-managed
```

This writes:

```text
/Library/Application Support/ClaudeCode/managed-settings.json
```

The installer preserves existing top-level managed settings and replaces only the `hooks` block. This is useful if another app rewrites `~/.claude/settings.json`.

Uninstall managed hooks:

```sh
make uninstall-managed
```

Check the current binary and managed hook configuration:

```sh
make doctor
```

### User Settings

If you prefer to manage Claude Code settings yourself:

```sh
make settings
```

Add the printed `hooks` object to `~/.claude/settings.json`.

## Active Terminal Suppression

If the foreground window looks like the same Claude Code terminal and macOS has received keyboard or mouse input recently, Sentinel suppresses the popover so the native terminal UI can handle the prompt.

Once the system has been idle for more than 8 seconds, or when another app is foreground, Sentinel shows the desktop prompt. If the hook fires while you are still in the Claude terminal, Sentinel keeps watching for up to 15 seconds and shows the prompt as soon as you switch away or become idle.

Tune the idle threshold and grace window in the environment where you start `claude`:

```sh
export CLAUDE_SENTINEL_ACTIVE_IDLE_SECONDS=10
export CLAUDE_SENTINEL_ACTIVE_GRACE_SECONDS=20
claude
```

Debug decisions are written to:

```text
~/Library/Logs/ClaudeCodeSentinel/hooks.log
```

## What It Handles

Sentinel uses Claude Code hooks, so it handles events Claude Code exposes through the hook system:

- `PermissionRequest`
- `PreToolUse` for `AskUserQuestion`
- `Notification`
- `Stop`
- `StopFailure`

It does not watch arbitrary interactive subprocess prompts inside a running shell command, such as a CLI asking `Continue? [y/N]` after Claude Code has already launched it. That would require a PTY wrapper layer.

## Maintainer Guide

For local development, release, and Homebrew tap automation, see the [Maintainer Guide](docs/maintainer.md).

## License

MIT
