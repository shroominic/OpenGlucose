#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

read_pin() {
  pin_file=$1
  [ -s "$repo_root/$pin_file" ] || die "missing repository pin $pin_file"
  sed -n '1p' "$repo_root/$pin_file"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH"
}

verify_java() {
  require_tool java
  expected_java=$(read_pin .java-version)
  actual_java=$(java -version 2>&1 | awk -F'"' 'NR == 1 {print $2}')
  actual_java_major=${actual_java%%.*}
  [ "$actual_java_major" = "$expected_java" ] ||
    die "Java $expected_java is required; found ${actual_java:-unknown}"
  printf 'Java %s matches the repository pin.\n' "$actual_java"
}

verify_ios() {
  [ "$(uname -s)" = Darwin ] || die 'iOS tooling is available only on macOS'
  require_tool xcodebuild
  require_tool pod

  expected_xcode=$(read_pin .xcode-version)
  actual_xcode=$(xcodebuild -version | awk 'NR == 1 {print $2}')
  [ "$actual_xcode" = "$expected_xcode" ] ||
    die "Xcode $expected_xcode is required; found $actual_xcode"

  expected_cocoapods=$(read_pin .cocoapods-version)
  actual_cocoapods=$(pod --version)
  [ "$actual_cocoapods" = "$expected_cocoapods" ] ||
    die "CocoaPods $expected_cocoapods is required; found $actual_cocoapods"

  printf 'Xcode %s and CocoaPods %s match repository pins.\n' \
    "$actual_xcode" "$actual_cocoapods"
}

verify_release() {
  verify_ios
  require_tool fastlane
  expected_fastlane=$(read_pin .fastlane-version)
  fastlane_output=$(fastlane --version 2>&1)
  actual_fastlane=$(
    printf '%s\n' "$fastlane_output" |
      sed -n 's/^fastlane \([0-9][0-9.]*\)$/\1/p' |
      tail -n 1
  )
  [ "$actual_fastlane" = "$expected_fastlane" ] ||
    die "Fastlane $expected_fastlane is required; found ${actual_fastlane:-unknown}"
  printf 'Fastlane %s matches the repository pin.\n' "$actual_fastlane"
}

case "${1:-}" in
  android) verify_java ;;
  ios) verify_ios ;;
  release) verify_release ;;
  *) die 'usage: verify-native-tooling.sh android|ios|release' ;;
esac
