#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
classes_dir=$(mktemp -d "${TMPDIR:-/tmp}/openglucose-yuwell-jvm.XXXXXX")

cleanup() {
  rm -R -- "$classes_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main_java="$repo_root/openhealth/android/app/src/main/java/com/aidex/aidex_flutter"
test_java="$repo_root/openhealth/android/app/src/test/java/com/aidex/aidex_flutter"

javac -d "$classes_dir" \
  "$main_java/YuwellWriteJournal.java" \
  "$main_java/YuwellStoreHealth.java" \
  "$main_java/YuwellPairRunAuthority.java" \
  "$test_java/YuwellWriteJournalTest.java" \
  "$test_java/YuwellStoreHealthTest.java" \
  "$test_java/YuwellPairRunAuthorityTest.java"

java -cp "$classes_dir" com.aidex.aidex_flutter.YuwellWriteJournalTest
java -cp "$classes_dir" com.aidex.aidex_flutter.YuwellStoreHealthTest
java -cp "$classes_dir" com.aidex.aidex_flutter.YuwellPairRunAuthorityTest
