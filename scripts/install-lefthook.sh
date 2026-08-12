#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
expected_version=2.1.9

if ! command -v lefthook >/dev/null 2>&1; then
  printf '%s\n' "error: Lefthook $expected_version is required." >&2
  printf '%s\n' 'Install it with Homebrew (brew install lefthook) or the versioned upstream package, then rerun this script.' >&2
  exit 1
fi

actual_version=$(lefthook version | awk '{print $NF}')
if [ "$actual_version" != "$expected_version" ]; then
  printf 'error: Lefthook %s is required; found %s.\n' "$expected_version" "$actual_version" >&2
  exit 1
fi

cd "$repo_root"
lefthook validate
lefthook install
printf 'Installed OpenGlucose hooks with Lefthook %s.\n' "$expected_version"
