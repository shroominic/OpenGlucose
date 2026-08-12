#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tools_bin="$repo_root/.dart_tool/quality-tools/bin"

[ -x "$tools_bin/shellcheck" ] || {
  printf '%s\n' 'error: pinned ShellCheck is missing; run make tooling-bootstrap' >&2
  exit 1
}
[ -x "$tools_bin/actionlint" ] || {
  printf '%s\n' 'error: pinned actionlint is missing; run make tooling-bootstrap' >&2
  exit 1
}

{
  find "$repo_root/scripts" -type f -name '*.sh' -print
  find "$repo_root/openhealth/scripts" -type f -name '*.sh' -print
} | sort | while IFS= read -r script; do
  "$tools_bin/shellcheck" "$script"
done

workflow_files=$(
  find "$repo_root/.github/workflows" -type f \
    \( -name '*.yml' -o -name '*.yaml' \) -print |
    sort
)
[ -n "$workflow_files" ] || {
  printf '%s\n' 'error: no GitHub Actions workflows were found' >&2
  exit 1
}
# Workflow paths are repository-controlled and cannot contain whitespace under
# the contribution policy, so intentional field splitting is safe here.
# shellcheck disable=SC2086
PATH="$tools_bin:$PATH" "$tools_bin/actionlint" -color=false $workflow_files

if [ -f "$repo_root/openhealth/fastlane/Fastfile" ]; then
  command -v ruby >/dev/null 2>&1 || {
    printf '%s\n' 'error: ruby is required to validate the Fastfile' >&2
    exit 1
  }
  ruby -c "$repo_root/openhealth/fastlane/Fastfile" >/dev/null
  ruby "$repo_root/scripts/test-notification-receipt.rb"
fi
