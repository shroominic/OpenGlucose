#!/usr/bin/env bash
#
# Install the project's git hooks (managed by Lefthook).
#
# Usage: ./scripts/install-hooks.sh   (or: make setup)
#
# Idempotent: safe to re-run. Requires `lefthook` on PATH; if it is missing this
# script tries to install it via Homebrew, then falls back to printing manual
# install instructions. commitlint runs on demand via `npx`, so it needs Node.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v lefthook >/dev/null 2>&1; then
  echo "lefthook not found; attempting to install..."
  if command -v brew >/dev/null 2>&1; then
    brew install lefthook
  elif command -v go >/dev/null 2>&1; then
    go install github.com/evilmartians/lefthook@latest
  else
    cat >&2 <<'EOF'
Could not auto-install lefthook. Install it manually, then re-run this script:
  macOS:  brew install lefthook
  Linux:  https://lefthook.dev/installation/
  Go:     go install github.com/evilmartians/lefthook@latest
EOF
    exit 1
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  echo "warning: Node.js not found. The commit-msg hook (commitlint via npx) will" >&2
  echo "         fail until Node is installed (https://nodejs.org)." >&2
fi

lefthook install
echo "Git hooks installed. Run 'lefthook run pre-commit' to test."
