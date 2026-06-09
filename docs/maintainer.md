# Maintainer Guide

This guide is for maintainers of Claude Code Sentinel.

## Local Development

```sh
make build
make test
```

The binary is written to:

```text
release/claude-code-sentinel
```

Generated binaries are ignored by git.

## Testing A Local Build With Claude Code

Install hooks that point to the local build:

```sh
make build
./release/claude-code-sentinel install-managed
```

Verify:

```sh
./release/claude-code-sentinel doctor
```

Switch back to the Homebrew build:

```sh
/opt/homebrew/bin/claude-code-sentinel install-managed
/opt/homebrew/bin/claude-code-sentinel doctor
```

## Testing A Local Build With OpenCode

Install the OpenCode plugin that points to the local build:

```sh
make build
make install-opencode
```

Verify:

```sh
make doctor-opencode
```

Restart the OpenCode session after installing the plugin. Smoke-test:

- a `question.asked` prompt, confirming the selected answer reaches OpenCode
- an `edit` or `bash` permission prompt, confirming `Yes`, `No`, and `Yes, always`
- an idle/completion notification
- a `session.error` notification

Diagnostic logs:

```text
~/Library/Logs/ClaudeCodeSentinel/hooks.log
~/Library/Logs/ClaudeCodeSentinel/opencode-plugin.log
```

The OpenCode installer must preserve unrelated keys in `~/.config/opencode/opencode.json`, especially existing `mcp` configuration.

## Merge Checklist

Before merging OpenCode support to `main`:

- `make test` passes
- `make doctor` passes for the intended Claude Code binary
- `make doctor-opencode` passes for the intended OpenCode plugin
- Claude Code `PermissionRequest`, `AskUserQuestion`, `Stop`, and `StopFailure` still behave as before
- OpenCode permission, question reply, idle notification, and error notification smoke tests pass
- README, README.en, and this maintainer guide describe the current commands
- `release/` artifacts, local settings, logs, screenshots with secrets, and tokens are not staged

## Release Process

Create a GitHub Release:

```sh
git tag v0.1.1
git push origin v0.1.1
```

After pushing a `v*` tag, GitHub Actions:

- builds a macOS universal binary
- uploads GitHub Release assets
- computes the SHA256 checksum
- updates the Formula in `hlongc/homebrew-tap`

## Homebrew Tap Automation

To enable automatic Homebrew tap updates, configure this secret in the `hlongc/claude-code-sentinel` repository:

```text
TAP_GITHUB_TOKEN
```

Use a fine-grained PAT with `Contents: Read and write` access to the `hlongc/homebrew-tap` repository.

## Launch Materials

See [launch-posts.md](launch-posts.md) for reusable announcement templates.
