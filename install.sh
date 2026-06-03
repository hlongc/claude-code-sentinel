#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${CLAUDE_SENTINEL_REPO_URL:-https://github.com/hlongc/claude-code-sentinel}"
REF="${CLAUDE_SENTINEL_REF:-main}"
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
need make
need swiftc

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/claude-code-sentinel.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

archive="$tmpdir/source.tar.gz"
src="$tmpdir/source"

echo "Downloading Claude Code Sentinel from $REPO_URL ($REF)..."
curl -fsSL "$REPO_URL/archive/refs/heads/$REF.tar.gz" -o "$archive"
mkdir -p "$src"
tar -xzf "$archive" -C "$src" --strip-components=1

echo "Building..."
make -C "$src" build

mkdir -p "$BINDIR"
cp "$src/release/$BIN_NAME" "$BINDIR/$BIN_NAME"
chmod +x "$BINDIR/$BIN_NAME"

echo "Installed $BIN_NAME to $BINDIR/$BIN_NAME"

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
