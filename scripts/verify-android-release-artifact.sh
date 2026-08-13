#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  printf 'usage: %s APK VERSION BUILD_NUMBER SIGNING_CERT_SHA256\n' "$0" >&2
  exit 64
fi

apk=$1
expected_version=$2
expected_build_number=$3
expected_signing_digest=$4
android_sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}

[ -f "$apk" ] || {
  printf 'release blocked: APK does not exist: %s\n' "$apk" >&2
  exit 1
}
[ -n "$android_sdk" ] || {
  printf 'release blocked: ANDROID_HOME or ANDROID_SDK_ROOT is required\n' >&2
  exit 1
}

build_tools_root=$android_sdk/build-tools
apksigner=$(find "$build_tools_root" -mindepth 2 -maxdepth 2 -type f \
  -name apksigner -print | sort -V | tail -n 1)
aapt=$(find "$build_tools_root" -mindepth 2 -maxdepth 2 -type f \
  -name aapt -print | sort -V | tail -n 1)
[ -n "$apksigner" ] && [ -x "$apksigner" ] || {
  printf 'release blocked: apksigner was not found in %s\n' "$build_tools_root" >&2
  exit 1
}
[ -n "$aapt" ] && [ -x "$aapt" ] || {
  printf 'release blocked: aapt was not found in %s\n' "$build_tools_root" >&2
  exit 1
}

signature_report=$($apksigner verify --verbose --print-certs --Werr "$apk")
printf '%s\n' "$signature_report" | grep -Fxq 'Verifies'
printf '%s\n' "$signature_report" | grep -Fxq 'Number of signers: 1' || {
  printf 'release blocked: APK must have exactly one signer\n' >&2
  exit 1
}
actual_signing_digest=$(
  printf '%s\n' "$signature_report" |
    sed -n 's/^.*certificate SHA-256 digest: //p' |
    head -n 1 |
    tr '[:lower:]' '[:upper:]' |
    tr -d ':[:space:]'
)
expected_signing_digest=$(
  printf '%s' "$expected_signing_digest" |
    tr '[:lower:]' '[:upper:]' |
    tr -d ':[:space:]'
)
historical_debug_digest=FE7F5535CA25326ED9B79D24B0CF0AE14B93C38C1424E35A9278E6D1976A9FC1
[ "$expected_signing_digest" != "$historical_debug_digest" ] || {
  printf 'release blocked: the historical Android debug certificate is forbidden\n' >&2
  exit 1
}
[ -n "$actual_signing_digest" ] && \
  [ "$actual_signing_digest" = "$expected_signing_digest" ] || {
    printf 'release blocked: signing certificate SHA-256 mismatch\n' >&2
    exit 1
  }
printf '%s\n' "$signature_report" |
  grep -Eq 'certificate DN:.*CN=Android Debug' && {
    printf 'release blocked: an Android Debug certificate signed the APK\n' >&2
    exit 1
  }

badging=$($aapt dump badging "$apk")
package_name=$(printf '%s\n' "$badging" |
  sed -n "s/^package: name='\([^']*\)'.*/\1/p")
version_code=$(printf '%s\n' "$badging" |
  sed -n "s/^package:.*versionCode='\([^']*\)'.*/\1/p")
version_name=$(printf '%s\n' "$badging" |
  sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p")

[ "$package_name" = com.openglucose.app ] || {
  printf 'release blocked: package is %s, expected com.openglucose.app\n' \
    "$package_name" >&2
  exit 1
}
[ "$version_name" = "$expected_version" ] || {
  printf 'release blocked: versionName is %s, expected %s\n' \
    "$version_name" "$expected_version" >&2
  exit 1
}
[ "$version_code" = "$expected_build_number" ] || {
  printf 'release blocked: versionCode is %s, expected %s\n' \
    "$version_code" "$expected_build_number" >&2
  exit 1
}
printf '%s\n' "$badging" | grep -Fq 'application-debuggable' && {
  printf 'release blocked: APK is debuggable\n' >&2
  exit 1
}
$aapt dump permissions "$apk" |
  grep -Fq "uses-permission: name='android.permission.INTERNET'" || {
    printf 'release blocked: Android release lacks INTERNET permission\n' >&2
    exit 1
  }

sha256sum "$apk" | awk '{print $1}'
