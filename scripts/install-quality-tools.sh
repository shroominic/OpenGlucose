#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tools_bin="$repo_root/.dart_tool/quality-tools/bin"
shellcheck_version=0.11.0
actionlint_version=1.7.12

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die 'sha256sum or shasum is required to verify downloaded tools'
  fi
}

verify_checksum() {
  archive=$1
  expected=$2
  actual=$(checksum "$archive")
  [ "$actual" = "$expected" ] || die "checksum mismatch for $(basename "$archive")"
}

shellcheck_installed=false
if [ -x "$tools_bin/shellcheck" ]; then
  installed_shellcheck=$("$tools_bin/shellcheck" --version | awk '/^version:/ {print $2}')
  [ "$installed_shellcheck" != "$shellcheck_version" ] || shellcheck_installed=true
fi

actionlint_installed=false
if [ -x "$tools_bin/actionlint" ]; then
  installed_actionlint=$("$tools_bin/actionlint" -version | awk 'NR == 1 {print $1}')
  [ "$installed_actionlint" != "$actionlint_version" ] || actionlint_installed=true
fi

if [ "$shellcheck_installed" = true ] && [ "$actionlint_installed" = true ]; then
  printf 'ShellCheck %s and actionlint %s are installed.\n' "$shellcheck_version" "$actionlint_version"
  exit 0
fi

command -v curl >/dev/null 2>&1 || die 'curl is required to install repository quality tools'
command -v tar >/dev/null 2>&1 || die 'tar is required to install repository quality tools'

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    shellcheck_platform=darwin.aarch64
    shellcheck_sha=339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f
    actionlint_platform=darwin_arm64
    actionlint_sha=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    ;;
  Darwin:x86_64)
    shellcheck_platform=darwin.x86_64
    shellcheck_sha=c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51
    actionlint_platform=darwin_amd64
    actionlint_sha=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
    ;;
  Linux:aarch64|Linux:arm64)
    shellcheck_platform=linux.aarch64
    shellcheck_sha=68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc
    actionlint_platform=linux_arm64
    actionlint_sha=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
    ;;
  Linux:x86_64|Linux:amd64)
    shellcheck_platform=linux.x86_64
    shellcheck_sha=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
    actionlint_platform=linux_amd64
    actionlint_sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    ;;
  *) die "unsupported quality-tool platform: $(uname -s) $(uname -m)" ;;
esac

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/openglucose-quality-tools.XXXXXX")
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

shellcheck_archive="$temporary_dir/shellcheck.tar.gz"
actionlint_archive="$temporary_dir/actionlint.tar.gz"

curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --output "$shellcheck_archive" \
  "https://github.com/koalaman/shellcheck/releases/download/v${shellcheck_version}/shellcheck-v${shellcheck_version}.${shellcheck_platform}.tar.gz"
verify_checksum "$shellcheck_archive" "$shellcheck_sha"

curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --output "$actionlint_archive" \
  "https://github.com/rhysd/actionlint/releases/download/v${actionlint_version}/actionlint_${actionlint_version}_${actionlint_platform}.tar.gz"
verify_checksum "$actionlint_archive" "$actionlint_sha"

mkdir -p "$temporary_dir/shellcheck" "$temporary_dir/actionlint" "$tools_bin"
tar -xzf "$shellcheck_archive" -C "$temporary_dir/shellcheck"
tar -xzf "$actionlint_archive" -C "$temporary_dir/actionlint"
install -m 0755 \
  "$temporary_dir/shellcheck/shellcheck-v${shellcheck_version}/shellcheck" \
  "$tools_bin/shellcheck"
install -m 0755 "$temporary_dir/actionlint/actionlint" "$tools_bin/actionlint"

printf 'Installed checksum-pinned ShellCheck %s and actionlint %s.\n' \
  "$shellcheck_version" "$actionlint_version"
