#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
native_tooling_verifier="$repo_root/scripts/verify-native-tooling.sh"
flutter_version=3.41.6
dart_version=3.11.4
project_dirs="
packages/cgm_core
packages/cgm_ble
packages/cgm_ble_flutter
packages/cgm_aidex
openhealth
"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH"
}

uses_flutter() {
  grep -q 'sdk: flutter' "$repo_root/$1/pubspec.yaml"
}

verify_runtime() {
  require_tool flutter
  require_tool dart

  actual_flutter=$(flutter --version --machine | awk -F'"' '/"frameworkVersion"/ {print $4; exit}')
  actual_dart=$(dart --version 2>&1 | awk '{print $4}')

  [ "$actual_flutter" = "$flutter_version" ] || die "Flutter $flutter_version is required; found $actual_flutter. Run 'fvm use'."
  [ "$actual_dart" = "$dart_version" ] || die "Dart $dart_version is required; found $actual_dart."
}

for_project() {
  operation=$1
  for project_dir in $project_dirs; do
    printf '\n==> %s: %s\n' "$project_dir" "$operation"
    (
      cd "$repo_root/$project_dir"
      case "$operation" in
        pub-get)
          if [ "$project_dir" = openhealth ]; then
            printf 'Restoring application dependencies from pubspec.lock.\n'
            flutter pub get --enforce-lockfile
          elif uses_flutter "$project_dir"; then
            printf 'Resolving unlocked Flutter package dependencies.\n'
            flutter pub get
          else
            printf 'Resolving unlocked Dart package dependencies.\n'
            dart pub get
          fi
          ;;
        format)
          set -- lib
          [ ! -d test ] || set -- "$@" test
          [ ! -d integration_test ] || set -- "$@" integration_test
          dart format "$@"
          ;;
        format-check)
          set -- lib
          [ ! -d test ] || set -- "$@" test
          [ ! -d integration_test ] || set -- "$@" integration_test
          dart format --output=none --set-exit-if-changed "$@"
          ;;
        analyze)
          if uses_flutter "$project_dir"; then
            flutter analyze --no-pub --fatal-infos
          else
            dart analyze --fatal-infos
          fi
          ;;
        test-unit)
          if [ -d test ]; then
            set --
            previous_ifs=$IFS
            IFS='
'
            for test_file in $(find test -type f -name '*_test.dart' ! -path 'test/integration/*' -print | sort); do
              set -- "$@" "$test_file"
            done
            IFS=$previous_ifs

            if [ "$#" -eq 0 ]; then
              printf 'No unit tests configured for %s.\n' "$project_dir"
            elif uses_flutter "$project_dir"; then
              flutter test --no-pub --exclude-tags integration "$@"
            else
              dart test --exclude-tags integration "$@"
            fi
          else
            printf 'No unit tests configured for %s.\n' "$project_dir"
          fi
          ;;
        *) die "unsupported project operation: $operation" ;;
      esac
    )
  done
}

integration_test_files() {
  project_path=$1
  for test_root in test integration_test; do
    [ ! -d "$project_path/$test_root" ] ||
      find "$project_path/$test_root" -type f -name '*_test.dart' -print
  done | sort -u | while IFS= read -r test_file; do
    relative_file=${test_file#"$project_path/"}
    case "$relative_file" in
      test/integration/*|integration_test/*)
        printf '%s\n' "$relative_file"
        ;;
      *)
        if grep -Eq "['\"]integration['\"]" "$test_file"; then
          printf '%s\n' "$relative_file"
        fi
        ;;
    esac
  done
}

run_project_tests() {
  project_dir=$1
  shift
  (
    cd "$repo_root/$project_dir"
    if uses_flutter "$project_dir"; then
      flutter test --no-pub "$@"
    else
      dart test "$@"
    fi
  )
}

run_integration_tests() {
  found=false

  for project_dir in $project_dirs; do
    project_path="$repo_root/$project_dir"
    discovered_files=$(integration_test_files "$project_path")
    if [ -n "$discovered_files" ]; then
      set --
      previous_ifs=$IFS
      IFS='
'
      for test_file in $discovered_files; do
        set -- "$@" "$test_file"
      done
      IFS=$previous_ifs

      printf '\n==> %s: discovered integration tests\n' "$project_dir"
      printf '  %s\n' "$@"
      found=true
      run_project_tests "$project_dir" "$@"
    fi
  done

  [ "$found" = true ] || die 'no tagged or directory-based integration tests were found'
}

verify_android_release_signing_guard() (
  verify_runtime
  "$native_tooling_verifier" android
  cd "$repo_root/openhealth"

  verification_log=$(mktemp "${TMPDIR:-/tmp}/openglucose-android-signing.XXXXXX")
  # Invoked indirectly by the trap below.
  # shellcheck disable=SC2329
  cleanup() {
    rm -f -- "$verification_log"
  }
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  set +e
  env \
    -u ANDROID_KEYSTORE_PATH \
    -u ANDROID_KEYSTORE_PASSWORD \
    -u ANDROID_KEY_ALIAS \
    -u ANDROID_KEY_PASSWORD \
    flutter build apk --release --no-pub >"$verification_log" 2>&1
  build_status=$?
  set -e

  [ "$build_status" -ne 0 ] ||
    die 'unsigned Android release build unexpectedly succeeded'
  grep -Fq \
    'Release signing is not configured.' \
    "$verification_log" || {
      cat "$verification_log" >&2
      die 'Android release failed without exercising the signing guard'
    }
  printf '%s\n' 'Android release signing guard failed closed as expected.'
)

run_ios_native_tests() {
  verify_runtime
  "$native_tooling_verifier" ios
  cd "$repo_root/openhealth/ios"
  xcodebuild test -quiet \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' \
    -only-testing:RunnerTests
}

outdated_dependencies() {
  verify_runtime
  for project_dir in $project_dirs; do
    printf '\n==> %s: outdated dependencies\n' "$project_dir"
    (
      cd "$repo_root/$project_dir"
      if grep -q 'sdk: flutter' pubspec.yaml; then
        flutter pub outdated --no-dependency-overrides
      else
        dart pub outdated --no-dependency-overrides
      fi
    )
  done
}

command_name=${1:-help}

case "$command_name" in
  doctor)
    verify_runtime
    printf 'Flutter %s and Dart %s match the repository pin.\n' "$flutter_version" "$dart_version"
    ;;
  pub-get|format|format-check|analyze|test-unit)
    verify_runtime
    for_project "$command_name"
    ;;
  outdated)
    outdated_dependencies
    ;;
  test-integration)
    verify_runtime
    run_integration_tests
    ;;
  test-e2e)
    printf '%s\n' 'Device end-to-end tests are not configured; see the controls register for the tracked exception.'
    ;;
  build-android)
    verify_runtime
    "$native_tooling_verifier" android
    cd "$repo_root/openhealth"
    flutter build apk --debug --no-pub
    ;;
  build-web)
    verify_runtime
    cd "$repo_root/openhealth"
    flutter build web --no-pub
    ;;
  build-ios)
    verify_runtime
    require_tool git
    "$native_tooling_verifier" ios
    cd "$repo_root/openhealth"
    flutter build ios --no-codesign --no-pub
    if [ -n "$(git status --porcelain -- ios/Podfile.lock)" ]; then
      git diff -- ios/Podfile.lock >&2
      die 'the iOS build changed ios/Podfile.lock; update and review the lockfile explicitly'
    fi
    ;;
  verify-android-release-signing)
    verify_android_release_signing_guard
    ;;
  test-ios-native)
    run_ios_native_tests
    ;;
  *)
    die "unknown command: $command_name"
    ;;
esac
