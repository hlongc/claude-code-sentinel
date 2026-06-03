# Launch Post Templates

Use these as starting points when announcing Claude Code Sentinel.

## X / Twitter

```text
I built Claude Code Sentinel for macOS.

Stop babysitting Claude Code:
- native approval popover
- approve / deny permissions
- answer AskUserQuestion prompts
- completion notifications
- Homebrew install

brew tap hlongc/tap
brew install claude-code-sentinel

GitHub: https://github.com/hlongc/claude-code-sentinel
```

## Hacker News

Title:

```text
Show HN: Claude Code Sentinel - macOS approval popovers for Claude Code
```

Body:

```text
I built a small native macOS companion for Claude Code.

The problem: Claude Code can run for a while, then pause on a permission approval or multiple-choice question. If I have switched to another app, I often miss it and the task sits blocked.

Claude Code Sentinel uses Claude Code hooks to show a lightweight approval popover:

- PermissionRequest: Yes / Yes, don't ask again / No
- AskUserQuestion: answer choices one at a time
- Stop / StopFailure: completion notifications
- active-terminal suppression so it stays quiet when you are already using the terminal

Install:

brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed

GitHub: https://github.com/hlongc/claude-code-sentinel
```

## Reddit

Suggested communities:

- r/ClaudeAI
- r/MacOS
- r/programming
- r/LocalLLaMA, if framed around coding agents

Title:

```text
I built a native macOS approval popover for Claude Code
```

Post:

```text
I use Claude Code a lot, and one recurring annoyance is that it can pause for a permission approval or multiple-choice question while I am working in another app.

I built Claude Code Sentinel to solve that:

- native macOS approval popover
- approve / deny / don't ask again
- supports AskUserQuestion prompts
- completion notifications
- Homebrew install

It uses Claude Code hooks rather than terminal scraping.

Install:

brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed

GitHub: https://github.com/hlongc/claude-code-sentinel

Feedback welcome.
```

## V2EX / 中文社区

标题：

```text
我做了一个 Claude Code 的 macOS 审批浮窗，再也不用一直盯着终端等确认
```

正文：

```text
我最近用 Claude Code 比较多，经常遇到一个问题：任务跑着跑着停在权限确认、多选问题或者工具调用确认上，但我已经切去做其他事了，回来才发现它卡了很久。

于是做了一个小工具：Claude Code Sentinel。

它是一个原生 macOS 浮窗工具，基于 Claude Code hooks：

- 权限确认时在右上角弹窗
- 可以直接选择 Yes / Yes, don't ask again / No
- 支持 AskUserQuestion 多选问题
- 任务完成或失败时提醒
- 如果你正在终端里操作，它会静默不打扰
- 支持 Homebrew 安装

安装：

brew tap hlongc/tap
brew install claude-code-sentinel
claude-code-sentinel install-managed

GitHub:
https://github.com/hlongc/claude-code-sentinel

欢迎试用和提建议。
```

## Demo Checklist

Record a 10-20 second GIF:

1. Start Claude Code in a terminal.
2. Trigger a permission prompt.
3. Switch to another app.
4. Show Sentinel appearing in the upper-right corner.
5. Click `Yes`.
6. Show Claude Code continuing.
7. Show a completion notification.

Suggested output path:

```text
assets/demo.gif
```
