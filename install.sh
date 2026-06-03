#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${CLAUDE_SENTINEL_REPO_URL:-https://github.com/hlongc/claude-code-sentinel}"
REF="${CLAUDE_SENTINEL_REF:-main}"
VERSION="${CLAUDE_SENTINEL_VERSION:-latest}"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
BIN_NAME="claude-code-sentinel"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need curl
need tar

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/claude-code-sentinel.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

archive="$tmpdir/source.tar.gz"
src="$tmpdir/source"
release_archive="$tmpdir/claude-code-sentinel-macos-universal.tar.gz"
installed_from_release=0

release_url() {
  if [[ "$VERSION" == "latest" ]]; then
    echo "$REPO_URL/releases/latest/download/claude-code-sentinel-macos-universal.tar.gz"
  else
    echo "$REPO_URL/releases/download/$VERSION/claude-code-sentinel-macos-universal.tar.gz"
  fi
}

install_binary() {
  mkdir -p "$BINDIR"
  cp "$1" "$BINDIR/$BIN_NAME"
  chmod +x "$BINDIR/$BIN_NAME"
  echo "Installed $BIN_NAME to $BINDIR/$BIN_NAME"
}

if [[ "${CLAUDE_SENTINEL_BUILD_FROM_SOURCE:-0}" != "1" ]]; then
  url="$(release_url)"
  echo "Downloading Claude Code Sentinel binary from $url..."
  if curl -fsSL "$url" -o "$release_archive"; then
    tar -xzf "$release_archive" -C "$tmpdir" "$BIN_NAME"
    install_binary "$tmpdir/$BIN_NAME"
    installed_from_release=1
  else
    echo "No release binary found. Falling back to source build."
  fi
fi

if [[ "$installed_from_release" != "1" ]]; then
  need make
  need swiftc

  echo "Downloading Claude Code Sentinel source from $REPO_URL ($REF)..."
  curl -fsSL "$REPO_URL/archive/refs/heads/$REF.tar.gz" -o "$archive"
  mkdir -p "$src"
  tar -xzf "$archive" -C "$src" --strip-components=1

  echo "Building..."
  make -C "$src" build
  install_binary "$src/release/$BIN_NAME"
fi

if [[ ":$PATH:" != *":$BINDIR:"* ]]; then
  echo
  echo "Note: $BINDIR is not in your PATH."
  echo "Add this to your shell profile if you want to run $BIN_NAME directly:"
  echo
  echo "  export PATH=\"$BINDIR:\$PATH\""
fi

echo
echo "Installing Claude Code managed hooks..."
"$BINDIR/$BIN_NAME" install-managed

echo
echo "Done. Run this to verify:"
echo
echo "  $BINDIR/$BIN_NAME doctor"
