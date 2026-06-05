# OpenCode Support TODO

Branch: `codex/opencode-support`

Goal: add OpenCode support without disturbing the existing Claude Code hook flow. Develop and test locally first, then merge to `main` and release only after the OpenCode path is verified.

## Plan

- [x] Confirm OpenCode plugin API and local config shape.
- [x] Inspect current Sentinel CLI boundaries and decide the smallest adapter surface.
- [x] Add OpenCode permission/notification CLI commands.
- [x] Add an OpenCode plugin bridge template in the repo.
- [x] Add `install-opencode` and `doctor-opencode` commands that preserve existing config.
- [x] Add focused tests for OpenCode payload formatting and config merging.
- [x] Run local OpenCode permission smoke test.
- [x] Run local OpenCode question reply smoke test.
- [x] Run local OpenCode idle/completion notification smoke test.
- [x] Run local OpenCode error notification smoke test.
- [x] Investigate OpenCode `question` tool support. Current language-choice UI is not a permission event.
- [x] Fix OpenCode plugin process invocation for Bun runtime compatibility.
- [x] Fix OpenCode question reply path for OpenCode 1.15.13.
- [x] Update README docs after behavior is verified.
- [x] Add Makefile targets for `install-opencode`, `uninstall-opencode`, and `doctor-opencode`.
- [x] Prepare merge/release checklist for `main`.

## Notes

- Existing Claude Code commands must keep their current behavior.
- `~/.config/opencode/opencode.json` already contains MCP config and must be preserved.
- Local OpenCode version observed: `1.15.13`.
- OpenCode loads local plugins from `~/.config/opencode/plugins/` and `.opencode/plugins/`.
- Local config originally had `$schema` and `mcp` only; installer now preserves those keys and adds missing `permission` settings.
- OpenCode defaults are permissive; `edit` and `bash` should be set to `ask` for Sentinel approvals to appear.
- Adapter shape: OpenCode plugin listens for permission/session events, calls Sentinel CLI, then replies through the OpenCode SDK client.
- Current implementation does not depend on the `opencode` binary path. It installs a plugin into OpenCode's config directory and embeds the current Sentinel binary path.
- `make test` passes after adding the first OpenCode adapter slice.
- First plugin version broke OpenCode startup because it called `client.app.log()` during plugin initialization. Removed all initialization-time client calls.
- OpenCode TUI starts with the updated plugin installed.
- OpenCode "Asked 1 question" choices appear to come from the `question` tool, exposed around `tool.execute.before`. This is not handled by the first permission adapter.
- Added a conservative `tool.question` notification fallback, but the primary path now handles `question.asked` and replies from the desktop prompt.
- OpenCode v2 SDK exposes `question.asked`, `client.question.reply`, and `client.question.reject`, but local OpenCode 1.15.13 plugin input worked best through the raw client endpoints.
- Added `opencode-question` and wired `question.asked` to a desktop choice dialog. Mock plugin test confirms answers are posted as `Array<Array<string>>`.
- Real OpenCode logs showed `question.asked` was published, but the plugin crashed before calling Sentinel with `stdio must be an array...`.
- Fixed plugin-to-Sentinel payload transport by passing JSON as `--payload-base64` instead of relying on Bun `spawnSync` stdin semantics.
- Real OpenCode 1.15.13 plugin input uses the classic SDK client, which does not expose `client.question`. The working question reply/reject API is available through the raw client endpoints, so the plugin posts to `/question/{requestID}/reply` and `/question/{requestID}/reject`.
- Real OpenCode permission smoke test passed on 2026-06-05 with `permission.result response:"always"` followed by `permission.reply.ok data:true`.
- Real OpenCode question smoke test passed on 2026-06-05 with `question.reply.ok data:true`.
- Real OpenCode idle/completion notification smoke test passed on 2026-06-05 with `OpenCodeNotification` shown for the `test-code` session.
- OpenCode error notification smoke test passed on 2026-06-05 by invoking `opencode-notification` with a `session.error` payload and observing `OpenCodeNotification` in `hooks.log`.
- OpenCode permission payloads may include a very large `metadata.diff`; the dialog formatter now shows a compact file/diff summary instead of dumping full `Metadata` and `Permission` JSON.
- README, README.en, and docs/maintainer.md now include OpenCode install, doctor, uninstall, smoke-test, and merge checklist guidance.
