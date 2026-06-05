# 从 Claude Code Hooks 到 OpenCode Plugins：AI Coding Agent 的可扩展机制实践

> 项目案例：Claude Code Sentinel，一个原生 macOS 审批浮窗工具，用来接管 Claude Code 的权限确认、多选问题和任务完成通知。
>
> GitHub 地址：[https://github.com/hlongc/claude-code-sentinel](https://github.com/hlongc/claude-code-sentinel)
>
> 如果你也经常让 Claude Code 在后台跑任务，却回来才发现它卡在权限确认上，这个项目就是为这个场景做的。本文会借它讲清楚 Claude Code Hooks 和 OpenCode Plugins 这两套扩展机制。

最近越来越多人开始深度使用 AI Coding Agent。刚开始大家关注的是模型效果、上下文长度、代码生成质量，但用久之后会发现，真正影响日常体验的还有另一层能力：**Agent 能不能被工程化地接入我们的工作流**。

比如：

- 执行危险命令前，能不能接入自定义审批？
- 改完文件后，能不能自动跑格式化或测试？
- Agent 卡在权限确认时，能不能弹通知提醒我？
- 多个终端任务同时跑时，能不能知道是哪一个项目在等我？

这些能力背后，靠的不是提示词，而是 Agent 产品提供的扩展机制。

本文主要聊两个机制：

- Claude Code 的 Hooks
- OpenCode 的 Plugins

最后会用我们做的一个 macOS 小工具作为实现案例，看看这些机制怎么落到真实项目里。

## 为什么需要 Hook / Plugin

AI Coding Agent 的核心循环大概是：

```text
用户输入需求
-> 模型规划下一步
-> 调用工具，比如读文件、改文件、跑命令
-> 拿到结果
-> 继续推理
-> 最终回复
```

如果这个循环完全封闭，用户只能通过 prompt 间接影响 Agent。

但工程场景里，我们经常需要确定性的控制：

```text
在工具执行前拦截
在工具执行后检查
在权限请求时接入审批
在任务结束时发通知
在会话出错时记录日志
```

这些事情不适合只靠“请你记得做”。更好的方式是：Agent 在关键生命周期点暴露事件，我们把自己的程序挂进去。

这就是 Claude Code Hooks 和 OpenCode Plugins 要解决的问题。

## Claude Code Hooks 是什么

Claude Code Hooks 是一种事件驱动机制。Claude Code 在特定时机触发 hook，然后执行你配置的命令。

最典型的数据流是：

```text
Claude Code event
-> 调用本地命令
-> 通过 stdin 传入 JSON
-> 命令处理后通过 stdout 返回 JSON
-> Claude Code 根据结果继续、拒绝或修改行为
```

配置通常放在 Claude Code settings 里，例如 `~/.claude/settings.json` 或 managed settings。

一个简化配置可能长这样：

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/claude-code-sentinel permission-request"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/claude-code-sentinel stop",
            "async": true
          }
        ]
      }
    ]
  }
}
```

这里有几个关键点：

| 概念 | 含义 |
| --- | --- |
| event | 触发时机，比如 `PreToolUse`、`PermissionRequest`、`Stop` |
| matcher | 匹配工具或事件，比如只匹配 `Edit`、`Bash` |
| command | 实际执行的本地命令 |
| stdin JSON | Claude Code 传给 hook 的上下文 |
| stdout JSON | hook 返回给 Claude Code 的决策 |

## Claude Code 常用 Hook 事件

实际开发里，最常用的是这些事件。

| Hook | 触发时机 | 典型用途 |
| --- | --- | --- |
| `PreToolUse` | 工具执行前 | 拦截危险命令、限制读写路径、修改 tool input |
| `PostToolUse` | 工具执行后 | 自动格式化、记录审计日志、跑轻量检查 |
| `PermissionRequest` | Claude Code 即将弹权限确认时 | 自定义审批 UI、远程审批、自动批准部分规则 |
| `Notification` | Claude Code 需要用户注意时 | 系统通知、声音提醒、IM 推送 |
| `Stop` | 当前响应结束时 | 任务完成通知、自动跑测试、汇总结果 |
| `StopFailure` | 响应失败时 | 失败通知、错误日志收集 |

其中 `PermissionRequest` 和 `PreToolUse` 都能参与权限控制，但语义不完全一样。

`PreToolUse` 更偏“工具执行前的通用拦截”。

`PermissionRequest` 更偏“Claude Code 原本就要问用户权限时，我来接管这个问题”。

## Claude Code Hook 的决策返回

以权限审批为例，Claude Code 会把工具名、参数、权限建议等信息传给 hook。

我们的程序可以返回类似这样的 JSON：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "permissionDecision": "allow"
  }
}
```

拒绝时可以返回：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "permissionDecision": "deny",
    "permissionDecisionReason": "This command is not allowed."
  }
}
```

如果希望“这次允许，并记住一条规则”，也可以带上 `updatedPermissions`。

这类能力非常适合做团队安全策略，例如：

```text
允许 git status
允许 npm test
执行 rm、curl | bash、写入系统目录时必须人工确认
```

## Claude Code Hooks 的优点和限制

Claude Code Hooks 的优点很明显：

| 优点 | 说明 |
| --- | --- |
| 简单 | 本质是命令行程序，任何语言都能写 |
| 稳定 | stdin / stdout JSON 协议清晰 |
| 可阻塞 | 某些 hook 可以阻止工具执行 |
| 易集成 | Shell、Swift、Node、Python、Go 都可以接 |
| 适合本地工具 | 特别适合通知、审批、安全检查 |

但也有一些边界：

| 限制 | 说明 |
| --- | --- |
| 只能处理 Claude Code 暴露的事件 | 已经运行中的子进程交互提示不属于 hook |
| async hook 不能控制行为 | 异步 hook 适合通知，不适合审批 |
| 不同事件返回结构不同 | `PermissionRequest`、`PreToolUse` 等字段要分别处理 |
| UI 要自己实现 | Claude Code 只负责调用 hook，不负责你的外部 UI |

所以 Hooks 更像一个“确定性执行点”。它给你控制权，但具体体验要自己做。

## OpenCode Plugins 是什么

OpenCode 的扩展方式和 Claude Code 不一样。

Claude Code 更像：

```text
配置一个 command hook
-> 事件触发时执行外部命令
```

OpenCode 更像：

```text
加载一个 JS/TS plugin
-> plugin 订阅 OpenCode 内部事件
-> plugin 直接调用 OpenCode SDK 或修改事件输出
```

OpenCode 官方支持把插件放在：

```text
~/.config/opencode/plugins/
.opencode/plugins/
```

也支持通过 `opencode.json` 的 `plugin` 字段加载 npm 包：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["my-opencode-plugin"]
}
```

一个最小插件大概长这样：

```js
export const MyPlugin = async ({ project, client, $, directory, worktree }) => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool === "bash") {
        console.log("about to run bash:", output.args.command)
      }
    }
  }
}
```

## OpenCode 插件事件

OpenCode 的事件覆盖面比较广，常见的有：

| 事件 | 用途 |
| --- | --- |
| `permission.asked` | 权限请求出现 |
| `permission.replied` | 用户已经回复权限请求 |
| `tool.execute.before` | 工具执行前 |
| `tool.execute.after` | 工具执行后 |
| `session.idle` | 会话进入空闲，通常表示当前轮结束 |
| `session.error` | 会话出错 |
| `message.updated` | 消息更新 |
| `file.edited` | 文件被修改 |
| `tui.toast.show` | TUI toast 提示 |
| `shell.env` | 注入 shell 环境变量 |

这套机制比 command hook 更“应用内”。插件能拿到 OpenCode 的上下文对象，也能使用 OpenCode SDK client。

## OpenCode 的权限模型

OpenCode 通过 `permission` 配置控制工具权限。

例如：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "edit": "ask",
    "bash": "ask"
  }
}
```

权限值通常有三种：

| 值 | 含义 |
| --- | --- |
| `allow` | 直接允许 |
| `ask` | 执行前询问用户 |
| `deny` | 禁止执行 |

OpenCode 的审批结果通常是：

| 结果 | 含义 |
| --- | --- |
| `once` | 只允许本次 |
| `always` | 本会话内记住类似规则 |
| `reject` | 拒绝 |

这和 Claude Code 的 `allow / deny / updatedPermissions` 很接近，但不是同一套协议。

## Claude Code Hooks 和 OpenCode Plugins 的对比

| 维度 | Claude Code Hooks | OpenCode Plugins |
| --- | --- | --- |
| 扩展形态 | 外部命令 | JS/TS 插件 |
| 配置入口 | Claude settings | `opencode.json` 或 plugins 目录 |
| 数据传递 | stdin / stdout JSON | 函数参数、SDK client、事件对象 |
| 权限接入 | `PermissionRequest`、`PreToolUse` | `permission.asked`、`permission.replied` |
| 通知接入 | `Notification`、`Stop`、`StopFailure` | `session.idle`、`session.error` |
| 语言自由度 | 任意语言 | 主要是 JS/TS |
| 部署方式 | 安装一个二进制或脚本 | 安装插件文件或 npm 包 |
| 控制粒度 | 强事件边界，协议清晰 | 更贴近 OpenCode 内部运行时 |
| 适合场景 | 本地命令、审批、安全策略、通知 | 深度集成、工具扩展、运行时增强 |

一句话总结：

```text
Claude Code Hooks 像“外部自动化接口”。
OpenCode Plugins 像“运行时扩展模块”。
```

## 实现案例：用 Sentinel 做 macOS 审批浮窗

我们做的 Claude Code Sentinel 是一个很小的 macOS 原生工具。

它解决的问题是：Claude Code 跑任务时经常停在权限确认、问题选择或任务完成提醒上。如果用户已经切到浏览器、文档或其他 IDE，很容易过很久才发现任务卡住了。

Sentinel 做的事情是：

```text
Claude Code hook 触发
-> Sentinel 收到 JSON
-> 在 macOS 右上角显示原生浮窗
-> 用户点击 Yes / No
-> Sentinel 把结果返回给 Claude Code
-> Claude Code 继续执行或拒绝
```

支持的场景包括：

| 场景 | 对应 Claude Code Hook |
| --- | --- |
| 权限审批 | `PermissionRequest` |
| 多选问题 | `PreToolUse` + `AskUserQuestion` |
| 普通通知 | `Notification` |
| 任务完成 | `Stop` |
| 任务失败 | `StopFailure` |

## Sentinel 的核心设计

### 1. 用 Swift 写原生 macOS UI

因为目标是 macOS 桌面浮窗，所以主程序使用 Swift + AppKit。

这样有几个好处：

- 不依赖 Node.js 运行时
- 不受用户当前 nvm / pnpm / bun 环境影响
- 可以直接调用 macOS Notification Center
- 可以做真正的浮窗、置顶、拖动、文本换行

### 2. Hook 输入统一格式化

Claude Code 传入的 tool input 不同工具结构不一样。

例如 Bash 关注：

```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm test",
    "description": "Run test suite"
  }
}
```

Edit 关注：

```json
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "src/App.tsx",
    "old_string": "...",
    "new_string": "..."
  }
}
```

Sentinel 会把这些结构格式化成适合用户阅读的审批内容。

### 3. 支持“本次允许”和“记住规则”

弹窗按钮映射大概是：

| 按钮 | Claude Code 决策 |
| --- | --- |
| `Yes` | `allow` |
| `Yes, don't ask again` | `allow` + `updatedPermissions` |
| `No` | `deny` |

这样既能快速通过当前请求，也能把一些重复请求变成会话内规则。

### 4. 活跃终端不打扰

如果用户当前就在 Claude Code 终端里，Sentinel 不应该再弹一个桌面浮窗抢焦点。

所以它会判断：

- 当前前台 app 是不是终端类应用
- 当前窗口标题是否像同一个 Claude Code 会话
- 系统最近是否有键盘或鼠标输入

如果用户正在操作终端，就保持安静，让 Claude Code 原生交互继续处理。

### 5. 避免重复提醒

有些场景下，任务刚刚 `Stop` 完成，Claude Code 过一会又发 `idle_prompt`，表示“等待用户继续输入”。

从 hook 语义上这是合理的，但用户体验上会变成：

```text
刚收到完成通知
-> 过一分钟又收到等待输入通知
```

Sentinel 里对同一 session 做了短时间抑制，避免这种重复噪音。

## 如果要支持 OpenCode，怎么做

OpenCode 不能直接复用 Claude Code 的 command hook 协议。

更合理的方案是做一个 OpenCode plugin bridge：

```text
OpenCode permission.asked
-> plugin 调用 sentinel opencode-permission
-> Sentinel 显示 macOS 审批浮窗
-> 用户选择 once / always / reject
-> plugin 把结果 reply 回 OpenCode
```

完成通知则是：

```text
OpenCode session.idle
-> plugin 调用 sentinel opencode-notification
-> Sentinel 发系统通知
```

也就是说，未来可以把 Sentinel 拆成两层：

```text
UI / 通知 / 活跃检测层
Claude Code adapter
OpenCode adapter
```

Claude Code adapter 负责 stdin/stdout JSON。

OpenCode adapter 负责 plugin 事件和 OpenCode SDK。

这样 UI 能复用，Agent 接入层可以扩展。

## 工程上的几个经验

### 1. 不要把 Hook 当成万能终端监听器

Hook 只能处理 Agent 暴露出来的生命周期事件。

如果 Claude Code 或 OpenCode 启动了一个子进程，而这个子进程自己在终端里问：

```text
Continue? [y/N]
```

这类交互不一定会进入 hook 或 plugin 权限流。要处理这种问题，通常需要 PTY wrapper，而不是普通 hook。

### 2. 审批内容一定要可读

权限系统最大的问题不是“能不能拦”，而是“用户能不能看懂自己在批准什么”。

不要只显示：

```text
Tool: Edit
```

应该尽量展示：

```text
Do you want to edit App.tsx?

File:
src/App.tsx

Input:
old_string: ...
new_string: ...
```

用户看懂了，审批才有意义。

### 3. 保留用户已有配置

无论是写 Claude Code settings，还是写 OpenCode `opencode.json`，都要保留用户已有配置。

比如用户本来有 MCP：

```json
{
  "mcp": {
    "feishu-mcp-pro": {}
  }
}
```

安装工具时只应该追加 hooks/plugin，不应该覆盖整个文件。

### 4. 调试日志非常重要

Hook 和 plugin 都属于“被 Agent 调用”的代码。出问题时用户很难第一时间看到 stdout/stderr。

所以一定要写日志，例如：

```text
~/Library/Logs/ClaudeCodeSentinel/hooks.log
```

日志里记录：

- event 类型
- tool 名称
- project
- session
- 前台 app
- 是否 suppress
- 用户选择结果

这对排查重复弹窗、没弹窗、错误审批非常关键。

## 小结

Claude Code Hooks 和 OpenCode Plugins 本质上都在解决同一个问题：

```text
把 AI Coding Agent 从一个封闭黑盒，变成可以接入工程系统的运行时。
```

但它们的设计取向不同：

```text
Claude Code Hooks 更像命令行自动化接口。
OpenCode Plugins 更像应用内运行时插件。
```

如果只是做通知、审批、安全拦截，Claude Code Hooks 非常直接。

如果要做更深的 OpenCode 集成，比如订阅事件、扩展工具、修改运行时行为，OpenCode Plugins 更自然。

对团队来说，理解这些机制的价值不只是“写几个脚本”，而是可以把 AI Agent 纳入已有工程规范：

- 权限审批
- 安全边界
- 日志审计
- 自动检查
- 团队默认配置
- 多工具统一体验

我们现在做的 Sentinel 只是一个很小的例子：用原生 macOS 浮窗接管 Claude Code 的权限确认和任务通知。后续如果接 OpenCode，也会沿着同一个思路扩展成多 Agent 的审批与通知层。

如果你对这个方向感兴趣，可以看下文中提到的实现案例：

[Claude Code Sentinel: macOS approval popovers for Claude Code](https://github.com/hlongc/claude-code-sentinel)

参考资料：

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide)
- [OpenCode Plugins](https://opencode.ai/docs/plugins/)
- [OpenCode Permissions](https://dev.opencode.ai/docs/permissions/)
- [OpenCode Agents](https://opencode.ai/docs/agents/)
