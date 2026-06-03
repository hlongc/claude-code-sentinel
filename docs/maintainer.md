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
