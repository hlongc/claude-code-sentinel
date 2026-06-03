# AGENTS.md

This file gives AI coding agents enough project context to work safely and effectively on Claude Code Sentinel.

## Project Overview

Claude Code Sentinel is a native macOS companion for Claude Code hooks. It shows lightweight approval popovers for permission prompts, handles `AskUserQuestion` choices, and sends completion/failure notifications.

The project is intentionally small:

- Main implementation: `Sources/ClaudeCodeSentinel/main.swift`
- Build entrypoint: `Makefile`
- User docs: `README.md` and `README.en.md`
- Maintainer docs: `docs/maintainer.md`
- Launch copy: `docs/launch-posts.md`
- One-line installer: `install.sh`
- Release workflow: `.github/workflows/release.yml`

The generated binary is `release/claude-code-sentinel`. `release/` is ignored by git.

## Core Behavior

Sentinel is invoked by Claude Code hooks. It is not a long-running service.

Supported hook paths:

- `PermissionRequest`
  - Shows a macOS approval popover.
  - Returns `allow`, `deny`, or `allow` with `updatedPermissions`.
  - Button labels map to `Yes`, `Yes, don't ask again`, and `No`.
- `PreToolUse` for `AskUserQuestion`
  - Shows one question at a time.
  - Returns selected answers through `updatedInput`.
- `Notification`
  - Forwards Claude Code notifications to macOS Notification Center.
- `Stop`
  - Sends completion notifications.
- `StopFailure`
  - Sends failure notifications.

It uses Claude Code hooks only. It does not inspect or control arbitrary subprocess prompts inside already-running shell commands.

## UI Notes

The popover is built with AppKit in `main.swift`.

Important UI properties:

- Fixed-width upper-right floating window.
- Content wraps instead of expanding horizontally.
- Window background can be dragged.
- Permission body uses a monospaced text area.
- Active-terminal suppression avoids showing popovers when the user is actively using the Claude terminal.

If editing UI code, verify long titles, long paths, long tool names, and JSON/command bodies do not stretch the window off-screen.

## Active Terminal Suppression

The suppression logic checks:

- frontmost application name
- frontmost window title
- terminal-like app detection
- system idle seconds via CoreGraphics

Default idle threshold:

```sh
CLAUDE_SENTINEL_ACTIVE_IDLE_SECONDS=20
```

Debug logs:

```text
~/Library/Logs/ClaudeCodeSentinel/hooks.log
```

Use logs to diagnose duplicate hooks, suppressed popovers, and unexpected notifications.

## Managed Settings

Preferred runtime configuration is Claude Code managed settings:

```text
/Library/Application Support/ClaudeCode/managed-settings.json
```

Install hooks:

```sh
claude-code-sentinel install-managed
```

Verify:

```sh
claude-code-sentinel doctor
```

Expected healthy state:

```text
Binary exists: yes
Managed hooks: present
Hook commands: 6
Commands pointing to this binary: 6
```

Avoid leaving duplicate hooks in `~/.claude/settings.json`. Duplicate user-level and managed hooks cause duplicate popovers and duplicate completion notifications.

## Development Workflow

Build and test:

```sh
make build
make test
```

Preview UI:

```sh
make sample-permission
make sample-stop
```

Print hook settings:

```sh
make settings
```

Install local build for Claude Code testing:

```sh
make build
./release/claude-code-sentinel install-managed
./release/claude-code-sentinel doctor
```

Switch back to Homebrew build:

```sh
/opt/homebrew/bin/claude-code-sentinel install-managed
/opt/homebrew/bin/claude-code-sentinel doctor
```

## Installation Paths

User-facing install options:

- Homebrew:
  ```sh
  brew tap hlongc/tap
  brew install claude-code-sentinel
  claude-code-sentinel install-managed
  ```
- One-line installer:
  ```sh
  curl -fsSL https://raw.githubusercontent.com/hlongc/claude-code-sentinel/main/install.sh | bash
  ```
- Source install:
  ```sh
  make install
  ```

`install.sh` prefers GitHub Release binaries and falls back to source builds.

## Release Workflow

Release automation lives in `.github/workflows/release.yml`.

Tag release:

```sh
git tag v0.1.1
git push origin v0.1.1
```

The workflow:

1. Builds arm64 and x86_64 binaries.
2. Combines them into a universal macOS binary.
3. Publishes GitHub Release assets.
4. Computes SHA256.
5. Updates `hlongc/homebrew-tap` Formula using `TAP_GITHUB_TOKEN`.

Maintainer details are in `docs/maintainer.md`.

## Git And Safety Notes

- Use Angular-style commit messages when possible, for example:
  - `feat(cli): add doctor command`
  - `fix(ui): wrap long permission text`
  - `docs(readme): simplify install guide`
  - `ci(release): update Homebrew tap on tags`
- Do not commit generated binaries from `release/`.
- Do not commit local Claude settings, tokens, screenshots with secrets, or logs.
- Be careful with `/Library/Application Support/ClaudeCode/managed-settings.json`; writes usually need administrator privileges.
- If changing managed settings behavior, preserve unrelated top-level keys in the JSON.

## Common Troubleshooting

Duplicate popovers:

- Check both managed settings and `~/.claude/settings.json`.
- Ensure only one hooks block is active.

Popover does not show:

- Check `~/Library/Logs/ClaudeCodeSentinel/hooks.log`.
- If no log entry exists, Claude Code likely did not invoke the hook.
- If `decision=suppress`, inspect `frontApp`, `frontTitle`, and `idleSeconds`.

Doctor reports wrong binary:

- Re-run `install-managed` from the desired binary path.
- Verify with the same binary:
  ```sh
  /opt/homebrew/bin/claude-code-sentinel doctor
  ```

Blank or stretched popover:

- Check `formatToolInput` and AppKit text wrapping.
- Make sure long text wraps and does not increase window width.
