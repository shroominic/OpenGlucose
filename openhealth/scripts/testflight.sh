#!/usr/bin/env bash
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
REPOSITORY_ROOT="$(cd "$ROOT/.." && pwd -P)"
RUNTIME_VERIFIER="$REPOSITORY_ROOT/scripts/flutter-workspace.sh"
NATIVE_TOOLING_VERIFIER="$REPOSITORY_ROOT/scripts/verify-native-tooling.sh"

fail() {
  echo "release blocked: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required; install and pin it before release"
}

assert_clean_source() {
  local context="$1"
  [[ -z "$(git status --porcelain --untracked-files=all)" ]] || \
    fail "$context changed the release worktree; review changes in a new commit"
  git diff --quiet || fail "$context left unstaged source changes"
  git diff --cached --quiet || fail "$context left staged source changes"
}

assert_hermetic_fastlane_environment() {
  local dotenv_path
  for dotenv_path in \
    "$ROOT/.env" \
    "$ROOT/.env.default" \
    "$ROOT/fastlane/.env" \
    "$ROOT/fastlane/.env.default"; do
    [[ ! -e "$dotenv_path" && ! -L "$dotenv_path" ]] || \
      fail "remove $dotenv_path; Fastlane auto-loads ignored dotenv files"
  done

  # These inherited variables can change authentication, team selection,
  # endpoints, TLS/proxy behavior, upload transport, or response logging in the
  # pinned Fastlane/Spaceship implementation. Release configuration must come
  # only from the explicit inputs validated by this script.
  local variable
  while IFS= read -r variable; do
    case "$variable" in
      PILOT_* | SPACESHIP_*)
        fail "$variable must be unset for a hermetic release"
        ;;
    esac
  done < <(compgen -e)

  for variable in \
    APP_STORE_CONNECT_API_KEY \
    TESTFLIGHT_APPLE_ID \
    RUBYOPT \
    RUBYLIB \
    RUBYGEMS_GEMDEPS \
    FASTLANE_GEM_HOME \
    BUNDLE_GEMFILE \
    GEM_HOME \
    GEM_PATH \
    SSL_CERT_FILE \
    SSL_CERT_DIR \
    FASTLANE_SESSION \
    FASTLANE_TEAM_ID \
    FASTLANE_TEAM_NAME \
    FASTLANE_ITC_TEAM_ID \
    FASTLANE_ITC_TEAM_NAME \
    FASTLANE_ITUNES_TRANSPORTER_PATH \
    FASTLANE_ITUNES_TRANSPORTER_USE_SHELL_SCRIPT \
    DELIVER_ALTOOL_ADDITIONAL_UPLOAD_PARAMETERS \
    DELIVER_ITMSTRANSPORTER_ADDITIONAL_UPLOAD_PARAMETERS \
    ITMSTRANSPORTER_FORCE_ITMS_PACKAGE_UPLOAD \
    VERBOSE \
    HTTP_PROXY \
    HTTPS_PROXY \
    ALL_PROXY \
    http_proxy \
    https_proxy \
    all_proxy; do
    [[ -z "${!variable+x}" ]] || \
      fail "$variable must be unset for a hermetic release"
  done
}

dependency_fingerprint() {
  shasum -a 256 pubspec.yaml pubspec.lock ios/Podfile ios/Podfile.lock
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || \
    fail "missing required plist value $key in $plist"
}

verify_signed_bundle() {
  local bundle="$1"
  local expected_bundle_id="$2"
  local label="$3"
  local entitlement_file="$4"
  local certificate_prefix="${5:-}"

  codesign --verify --strict --verbose=2 "$bundle"

  local signed_bundle_id
  signed_bundle_id=$(plist_value "$bundle/Info.plist" CFBundleIdentifier)
  [[ "$signed_bundle_id" == "$expected_bundle_id" ]] || \
    fail "$label bundle ID ($signed_bundle_id) does not match $expected_bundle_id"

  local signed_version
  signed_version=$(plist_value "$bundle/Info.plist" CFBundleShortVersionString)
  [[ "$signed_version" == "$EXPECTED_MARKETING_VERSION" ]] || \
    fail "$label version ($signed_version) does not match $EXPECTED_MARKETING_VERSION"

  local signed_build
  signed_build=$(plist_value "$bundle/Info.plist" CFBundleVersion)
  [[ "$signed_build" == "$EXPECTED_BUILD_NUMBER" ]] || \
    fail "$label build ($signed_build) does not match $EXPECTED_BUILD_NUMBER"

  local team_identifier
  team_identifier=$(
    codesign -dv --verbose=4 "$bundle" 2>&1 |
      sed -n 's/^TeamIdentifier=//p'
  )
  [[ "$team_identifier" == "$APPLE_TEAM_ID" ]] || \
    fail "$label signing team ($team_identifier) does not match $APPLE_TEAM_ID"

  codesign -d --entitlements :- "$bundle" >"$entitlement_file" 2>/dev/null || \
    fail "could not extract $label signed entitlements"
  [[ -s "$entitlement_file" ]] || fail "$label has no signed entitlements"

  local entitlement_team
  entitlement_team=$(
    plist_value "$entitlement_file" com.apple.developer.team-identifier
  )
  [[ "$entitlement_team" == "$APPLE_TEAM_ID" ]] || \
    fail "$label entitlement team ($entitlement_team) does not match $APPLE_TEAM_ID"

  local application_identifier
  application_identifier=$(plist_value "$entitlement_file" application-identifier)
  [[ "$application_identifier" == "$APPLE_TEAM_ID.$expected_bundle_id" ]] || \
    fail "$label application-identifier entitlement is $application_identifier"

  if [[ -n "$certificate_prefix" ]]; then
    codesign -d --extract-certificates "$certificate_prefix" "$bundle" \
      >/dev/null 2>&1 || fail "could not extract $label signing certificate"
    [[ -f "${certificate_prefix}0" ]] || \
      fail "$label has no leaf signing certificate"
    local actual_certificate_sha1
    actual_certificate_sha1=$(shasum -a 1 "${certificate_prefix}0" | awk '{print toupper($1)}')
    [[ "$actual_certificate_sha1" == "$IOS_DISTRIBUTION_CERTIFICATE_SHA1" ]] || \
      fail "$label signing certificate does not match approved input"
  fi
}

verify_main_app_healthkit_entitlement() {
  local entitlement_file="$1"
  local healthkit_enabled
  healthkit_enabled=$(
    plist_value "$entitlement_file" com.apple.developer.healthkit
  )
  [[ "$healthkit_enabled" == "true" ]] || \
    fail "main app signed entitlements do not enable HealthKit"
  if /usr/libexec/PlistBuddy \
    -c "Print :com.apple.developer.healthkit.access" \
    "$entitlement_file" >/dev/null 2>&1; then
    fail "main app unexpectedly requests Health Records access"
  fi
}

verify_distribution_profile() {
  local bundle="$1"
  local expected_bundle_id="$2"
  local label="$3"
  local profile_plist="$4"
  local expected_profile_uuid="${5:-}"
  local expected_certificate_sha1="${6:-}"
  local embedded_profile="$bundle/embedded.mobileprovision"

  [[ -f "$embedded_profile" ]] || \
    fail "$label has no embedded.mobileprovision"
  security cms -D -i "$embedded_profile" >"$profile_plist" || \
    fail "could not decode $label embedded.mobileprovision"
  [[ -s "$profile_plist" ]] || fail "$label provisioning profile is empty"

python3 - \
  "$profile_plist" \
  "$expected_bundle_id" \
  "$APPLE_TEAM_ID" \
  "$label" \
  "$expected_profile_uuid" \
  "$expected_certificate_sha1" <<'PY'
import datetime as dt
import hashlib
import plistlib
import sys

profile_path, bundle_id, team_id, label, expected_uuid, expected_cert_sha1 = sys.argv[1:]
with open(profile_path, "rb") as source:
    profile = plistlib.load(source)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"release blocked: {label} {message}")


expiration = profile.get("ExpirationDate")
require(isinstance(expiration, dt.datetime), "profile has no expiration date")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=dt.timezone.utc)
require(expiration > dt.datetime.now(dt.timezone.utc), "profile is expired")
require("ProvisionedDevices" not in profile, "uses device provisioning")
require(profile.get("ProvisionsAllDevices") is not True, "uses enterprise provisioning")
if expected_uuid:
    require(profile.get("UUID") == expected_uuid, "profile UUID does not match approved input")

teams = profile.get("TeamIdentifier")
require(isinstance(teams, list) and teams == [team_id], "profile team is not exact")
entitlements = profile.get("Entitlements")
require(isinstance(entitlements, dict), "profile has no entitlements")
require(entitlements.get("get-task-allow") is False, "allows debugger attachment")
require(entitlements.get("beta-reports-active") is True, "is not App Store/TestFlight distribution")
require(
    entitlements.get("com.apple.developer.team-identifier") == team_id,
    "entitlement team does not match",
)
require(
    entitlements.get("application-identifier") == f"{team_id}.{bundle_id}",
    "application identifier does not match",
)
if expected_cert_sha1:
    certificates = profile.get("DeveloperCertificates")
    require(
        isinstance(certificates, list) and len(certificates) == 1,
        "profile does not contain exactly one signing certificate",
    )
    actual_cert_sha1 = hashlib.sha1(certificates[0]).hexdigest().upper()
    require(
        actual_cert_sha1 == expected_cert_sha1,
        "profile signing certificate does not match approved input",
    )
PY
}

verify_main_app_healthkit_profile() {
  local profile_plist="$1"
  python3 - "$profile_plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    profile = plistlib.load(source)

entitlements = profile.get("Entitlements")
if not isinstance(entitlements, dict) or entitlements.get("com.apple.developer.healthkit") is not True:
    raise SystemExit("release blocked: main app profile does not enable HealthKit")
PY
}

# This must run before even `fastlane --version`; the pinned Fastlane CLI loads
# dotenv files before dispatching commands, including its version command.
assert_hermetic_fastlane_environment

require_command git
require_command flutter
require_command fastlane
require_command python3
require_command shasum
require_command unzip
require_command codesign
require_command security
require_command openssl
require_command xcodebuild
require_command pod
[[ -x "$RUNTIME_VERIFIER" ]] || fail "repository runtime verifier is missing"
[[ -x "$NATIVE_TOOLING_VERIFIER" ]] || \
  fail "repository native-tooling verifier is missing"
[[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy is required"

: "${ASC_API_KEY_ID:?missing ASC_API_KEY_ID}"
: "${ASC_API_ISSUER_ID:?missing ASC_API_ISSUER_ID}"
: "${ASC_API_KEY_PATH:?missing ASC_API_KEY_PATH}"
: "${APPLE_TEAM_ID:?missing APPLE_TEAM_ID}"
: "${APP_BUNDLE_ID:?missing APP_BUNDLE_ID}"
: "${LIVE_ACTIVITY_BUNDLE_ID:?missing LIVE_ACTIVITY_BUNDLE_ID}"
: "${RELEASE_VERSION:?missing RELEASE_VERSION (must match pubspec.yaml)}"
: "${RELEASE_COMMIT:?missing RELEASE_COMMIT (must match HEAD)}"
: "${TESTFLIGHT_GROUP:?missing TESTFLIGHT_GROUP}"

TESTFLIGHT_MODE="${TESTFLIGHT_MODE:-external}"
[[ "$TESTFLIGHT_MODE" == "external" || "$TESTFLIGHT_MODE" == "internal" ]] || \
  fail "TESTFLIGHT_MODE must be external or internal"
TESTFLIGHT_NOTIFY_ONLY="${TESTFLIGHT_NOTIFY_ONLY:-no}"
[[ "$TESTFLIGHT_NOTIFY_ONLY" == "yes" || "$TESTFLIGHT_NOTIFY_ONLY" == "no" ]] || \
  fail "TESTFLIGHT_NOTIFY_ONLY must be yes or no"
if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then
  [[ "$TESTFLIGHT_NOTIFY_ONLY" == "no" ]] || \
    fail "internal TestFlight mode does not support notify-only runs"
  : "${TESTFLIGHT_GROUP_ID:?missing immutable TESTFLIGHT_GROUP_ID for internal mode}"
  : "${TESTFLIGHT_TESTER_ID:?missing immutable TESTFLIGHT_TESTER_ID for internal mode}"
  : "${APP_STORE_PROFILE_UUID:?missing APP_STORE_PROFILE_UUID for internal mode}"
  : "${LIVE_ACTIVITY_APP_STORE_PROFILE_UUID:?missing LIVE_ACTIVITY_APP_STORE_PROFILE_UUID for internal mode}"
  : "${IOS_DISTRIBUTION_CERTIFICATE_SHA1:?missing IOS_DISTRIBUTION_CERTIFICATE_SHA1 for internal mode}"
  : "${TESTFLIGHT_CHANGELOG:?missing TESTFLIGHT_CHANGELOG}"
elif [[ "$TESTFLIGHT_NOTIFY_ONLY" == "yes" ]]; then
  : "${TESTFLIGHT_GROUP_ID:?missing immutable TESTFLIGHT_GROUP_ID for notify-only mode}"
else
  : "${TESTFLIGHT_CHANGELOG:?missing TESTFLIGHT_CHANGELOG}"
fi
[[ "$APPLE_TEAM_ID" =~ ^[A-Za-z0-9]{10}$ ]] || \
  fail "APPLE_TEAM_ID is malformed"
[[ "$APP_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  fail "APP_BUNDLE_ID is malformed"
[[ "$LIVE_ACTIVITY_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  fail "LIVE_ACTIVITY_BUNDLE_ID is malformed"
if [[ -n "${TESTFLIGHT_GROUP_ID:-}" ]]; then
  [[ "$TESTFLIGHT_GROUP_ID" =~ ^[A-Za-z0-9-]+$ ]] || \
    fail "TESTFLIGHT_GROUP_ID is malformed"
fi
if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then
  [[ "$APP_STORE_PROFILE_UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || \
    fail "APP_STORE_PROFILE_UUID must be a canonical UUID"
  [[ "$LIVE_ACTIVITY_APP_STORE_PROFILE_UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || \
    fail "LIVE_ACTIVITY_APP_STORE_PROFILE_UUID must be a canonical UUID"
  [[ "$IOS_DISTRIBUTION_CERTIFICATE_SHA1" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    fail "IOS_DISTRIBUTION_CERTIFICATE_SHA1 must be 40 hexadecimal characters"
  IOS_DISTRIBUTION_CERTIFICATE_SHA1=${IOS_DISTRIBUTION_CERTIFICATE_SHA1^^}
  export IOS_DISTRIBUTION_CERTIFICATE_SHA1
fi
if [[ -n "${TESTFLIGHT_TESTER_ID:-}" ]]; then
  [[ "$TESTFLIGHT_TESTER_ID" =~ ^[A-Za-z0-9-]+$ ]] || \
    fail "TESTFLIGHT_TESTER_ID is malformed"
fi

if [[ "$TESTFLIGHT_MODE" == "external" ]]; then
  : "${TESTFLIGHT_NOTIFICATION_RECEIPT_PATH:?missing TESTFLIGHT_NOTIFICATION_RECEIPT_PATH}"
  [[ "$TESTFLIGHT_NOTIFICATION_RECEIPT_PATH" == /* ]] || \
    fail "TESTFLIGHT_NOTIFICATION_RECEIPT_PATH must be absolute"
  [[ "$TESTFLIGHT_NOTIFICATION_RECEIPT_PATH" != *:* ]] || \
    fail "TESTFLIGHT_NOTIFICATION_RECEIPT_PATH cannot contain a colon"
  receipt_parent_input=$(dirname -- "$TESTFLIGHT_NOTIFICATION_RECEIPT_PATH")
  receipt_name=$(basename -- "$TESTFLIGHT_NOTIFICATION_RECEIPT_PATH")
  [[ "$receipt_name" != "." && "$receipt_name" != ".." ]] || \
    fail "TESTFLIGHT_NOTIFICATION_RECEIPT_PATH must name a file"
  [[ -d "$receipt_parent_input" ]] || \
    fail "notification receipt parent directory does not exist"
  receipt_parent=$(cd "$receipt_parent_input" && pwd -P)
  case "$receipt_parent/" in
    "$REPOSITORY_ROOT/"*)
      fail "notification receipt must be stored outside the repository"
      ;;
  esac
  receipt_parent_mode=$(/usr/bin/stat -f '%Lp' "$receipt_parent")
  [[ "$receipt_parent_mode" == "700" ]] || \
    fail "notification receipt parent must have mode 700 (found $receipt_parent_mode)"
  NOTIFICATION_RECEIPT_PATH="$receipt_parent/$receipt_name"
  if [[ -e "$NOTIFICATION_RECEIPT_PATH" || -L "$NOTIFICATION_RECEIPT_PATH" ]]; then
    [[ -f "$NOTIFICATION_RECEIPT_PATH" && ! -L "$NOTIFICATION_RECEIPT_PATH" ]] || \
      fail "notification receipt must be a regular non-symlink file"
    notification_receipt_mode=$(/usr/bin/stat -f '%Lp' "$NOTIFICATION_RECEIPT_PATH")
    [[ "$notification_receipt_mode" == "400" || "$notification_receipt_mode" == "600" ]] || \
      fail "notification receipt must have mode 400 or 600 (found $notification_receipt_mode)"
    [[ "$TESTFLIGHT_NOTIFY_ONLY" == "yes" ]] || \
      fail "notification receipt already exists; use notify-only mode to verify it"
  fi
fi

[[ "${RELEASE_APPROVED:-}" == "yes" ]] || \
  fail "set RELEASE_APPROVED=yes after the release checklist is approved"
internal_gate="${DISTRIBUTE_INTERNAL:-no}"
external_gate="${DISTRIBUTE_EXTERNAL:-no}"
[[ "$internal_gate" == "yes" || "$internal_gate" == "no" ]] || \
  fail "DISTRIBUTE_INTERNAL must be yes or no"
[[ "$external_gate" == "yes" || "$external_gate" == "no" ]] || \
  fail "DISTRIBUTE_EXTERNAL must be yes or no"
if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then
  [[ "$internal_gate" == "yes" ]] || \
    fail "set DISTRIBUTE_INTERNAL=yes to authorize the exact internal audience"
  [[ "$external_gate" == "no" ]] || \
    fail "DISTRIBUTE_EXTERNAL must be no in internal mode"
else
  [[ "$external_gate" == "yes" ]] || \
    fail "set DISTRIBUTE_EXTERNAL=yes to authorize external tester distribution"
  [[ "$internal_gate" == "no" ]] || \
    fail "DISTRIBUTE_INTERNAL must be no in external mode"
fi
[[ -f "$ASC_API_KEY_PATH" ]] || fail "App Store Connect key not found"

key_mode=$(/usr/bin/stat -f '%Lp' "$ASC_API_KEY_PATH")
[[ "$key_mode" == "400" || "$key_mode" == "600" ]] || \
  fail "ASC_API_KEY_PATH must have mode 400 or 600 (found $key_mode)"

# This is the repository's single exact Flutter/Dart runtime verifier. The
# build below must not have an independent, drifting version check.
"$RUNTIME_VERIFIER" doctor
"$NATIVE_TOOLING_VERIFIER" release

head_commit=$(git rev-parse HEAD)
[[ "$RELEASE_COMMIT" == "$head_commit" ]] || \
  fail "RELEASE_COMMIT does not match HEAD ($head_commit)"
assert_clean_source "release startup"

pubspec_version=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml)
[[ -n "$pubspec_version" ]] || fail "pubspec.yaml has no version"
[[ "$RELEASE_VERSION" == "$pubspec_version" ]] || \
  fail "RELEASE_VERSION ($RELEASE_VERSION) does not match pubspec.yaml ($pubspec_version)"
[[ "$RELEASE_VERSION" == *+* ]] || \
  fail "RELEASE_VERSION must include a numeric build suffix (for example 1.2.3+45)"
EXPECTED_MARKETING_VERSION="${RELEASE_VERSION%+*}"
EXPECTED_BUILD_NUMBER="${RELEASE_VERSION##*+}"
[[ "$EXPECTED_MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail "release marketing version must use major.minor.patch"
[[ "$EXPECTED_BUILD_NUMBER" =~ ^[0-9]+$ ]] || \
  fail "release build number must be numeric"
export EXPECTED_MARKETING_VERSION EXPECTED_BUILD_NUMBER

grep -Fq "PRODUCT_BUNDLE_IDENTIFIER = $APP_BUNDLE_ID;" \
  ios/Runner.xcodeproj/project.pbxproj || \
  fail "APP_BUNDLE_ID ($APP_BUNDLE_ID) is not configured for Runner"
grep -Fq "PRODUCT_BUNDLE_IDENTIFIER = $LIVE_ACTIVITY_BUNDLE_ID;" \
  ios/Runner.xcodeproj/project.pbxproj || \
  fail "LIVE_ACTIVITY_BUNDLE_ID ($LIVE_ACTIVITY_BUNDLE_ID) is not configured"
[[ "$LIVE_ACTIVITY_BUNDLE_ID" == "$APP_BUNDLE_ID."* ]] || \
  fail "Live Activity bundle ID must be namespaced below the app bundle ID"

release_temp=$(mktemp -d "${TMPDIR:-/tmp}/openglucose-release.XXXXXX")
cleanup() {
  case "${release_temp:-}" in
    "${TMPDIR:-/tmp}"/openglucose-release.*)
      rm -rf -- "$release_temp"
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

credential_json="$release_temp/app-store-connect.json"
export FASTLANE_SKIP_DOCS=1
export FASTLANE_SKIP_UPDATE_CHECK=1
export FL_REPORT_PATH="$release_temp/fastlane-reports"
mkdir -m 700 "$FL_REPORT_PATH"

python3 - "$ASC_API_KEY_PATH" "$ASC_API_KEY_ID" "$ASC_API_ISSUER_ID" "$credential_json" <<'PY'
import json
import os
import sys

key_path, key_id, issuer_id, output_path = sys.argv[1:]
with open(key_path, encoding="utf-8") as source:
    key = source.read()
descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as output:
    json.dump(
        {
            "key_id": key_id,
            "issuer_id": issuer_id,
            "key": key,
            "in_house": False,
        },
        output,
    )
PY

group_id_file="$release_temp/testflight-group-id"
group_options=(
  "api_key_path:$credential_json"
  "bundle_id:$APP_BUNDLE_ID"
  "group_name:$TESTFLIGHT_GROUP"
  "result_path:$group_id_file"
)
if [[ -n "${TESTFLIGHT_GROUP_ID:-}" ]]; then
  group_options+=("group_id:$TESTFLIGHT_GROUP_ID")
fi
if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then
  group_options+=("expected_tester_id:$TESTFLIGHT_TESTER_ID")
  fastlane ios verify_internal_group "${group_options[@]}"
else
  fastlane ios verify_external_group "${group_options[@]}"
fi
[[ -s "$group_id_file" ]] || fail "approved TestFlight group ID was not recorded"
approved_group_id=$(<"$group_id_file")
[[ "$approved_group_id" =~ ^[A-Za-z0-9-]+$ ]] || \
  fail "approved TestFlight group ID is malformed"
echo "==> Approved $TESTFLIGHT_MODE group ID: $approved_group_id"

if [[ "$TESTFLIGHT_NOTIFY_ONLY" == "yes" ]]; then
  echo "==> Verifying the exact build and sending the deferred tester notification"
  fastlane ios notify_external_build \
    "api_key_path:$credential_json" \
    "bundle_id:$APP_BUNDLE_ID" \
    "group_name:$TESTFLIGHT_GROUP" \
    "group_id:$approved_group_id" \
    "version:$EXPECTED_MARKETING_VERSION" \
    "build_number:$EXPECTED_BUILD_NUMBER" \
    "source_commit:$head_commit" \
    "notification_receipt_path:$NOTIFICATION_RECEIPT_PATH"
  echo "==> Verified audience and notification receipt for $RELEASE_VERSION ($head_commit)"
  exit 0
fi

echo "==> Restoring locked dependencies"
flutter pub get --enforce-lockfile
assert_clean_source "dependency restore"
dependency_state_before=$(dependency_fingerprint)

echo "==> Building committed version $RELEASE_VERSION from $head_commit"
if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then
  internal_export_options="$release_temp/internal-export-options.plist"
  cat >"$internal_export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$IOS_DISTRIBUTION_CERTIFICATE_SHA1</string>
  <key>teamID</key>
  <string>$APPLE_TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>testFlightInternalTestingOnly</key>
  <true/>
  <key>provisioningProfiles</key>
  <dict>
    <key>$APP_BUNDLE_ID</key>
    <string>$APP_STORE_PROFILE_UUID</string>
    <key>$LIVE_ACTIVITY_BUNDLE_ID</key>
    <string>$LIVE_ACTIVITY_APP_STORE_PROFILE_UUID</string>
  </dict>
</dict>
</plist>
PLIST
  flutter build ipa \
    --release \
    --no-pub \
    --export-options-plist="$internal_export_options"
else
  flutter build ipa --release --no-pub --export-method app-store
fi

# Builds and CocoaPods hooks can rewrite tracked dependency state. Verify both
# the entire worktree and the dependency inputs again before trusting the IPA.
assert_clean_source "release build"
post_build_commit=$(git rev-parse HEAD)
[[ "$post_build_commit" == "$head_commit" ]] || \
  fail "HEAD changed during the release build ($head_commit -> $post_build_commit)"
dependency_state_after=$(dependency_fingerprint)
[[ "$dependency_state_after" == "$dependency_state_before" ]] || \
  fail "release build changed locked dependency state"

shopt -s nullglob
ipas=("$ROOT"/build/ios/ipa/*.ipa)
[[ ${#ipas[@]} -eq 1 ]] || fail "expected exactly one IPA, found ${#ipas[@]}"
ipa="${ipas[0]}"
artifact_sha256=$(shasum -a 256 "$ipa" | awk '{print $1}')
echo "    IPA: $ipa"
echo "    SHA-256: $artifact_sha256"

verification_dir="$release_temp/verify"
mkdir -m 700 "$verification_dir"
unzip -qq "$ipa" -d "$verification_dir"
apps=("$verification_dir"/Payload/*.app)
[[ ${#apps[@]} -eq 1 ]] || fail "expected exactly one signed app in the IPA"
app="${apps[0]}"

extensions=("$app"/PlugIns/*.appex)
[[ ${#extensions[@]} -eq 1 ]] || \
  fail "expected exactly one signed app extension, found ${#extensions[@]}"
live_activity_extension="${extensions[0]}"

if find "$app" -name 'Runner.debug.dylib' -print -quit | grep -q .; then
  fail "release IPA contains Runner.debug.dylib"
fi

codesign --verify --deep --strict --verbose=2 "$app"
verify_signed_bundle \
  "$app" "$APP_BUNDLE_ID" "main app" "$release_temp/main-entitlements.plist" \
  "${IOS_DISTRIBUTION_CERTIFICATE_SHA1:+$release_temp/main-certificate-}"
verify_main_app_healthkit_entitlement "$release_temp/main-entitlements.plist"
verify_signed_bundle \
  "$live_activity_extension" "$LIVE_ACTIVITY_BUNDLE_ID" \
  "Live Activity extension" "$release_temp/extension-entitlements.plist" \
  "${IOS_DISTRIBUTION_CERTIFICATE_SHA1:+$release_temp/extension-certificate-}"
verify_distribution_profile \
  "$app" "$APP_BUNDLE_ID" "main app" "$release_temp/main-profile.plist" \
  "${APP_STORE_PROFILE_UUID:-}" "${IOS_DISTRIBUTION_CERTIFICATE_SHA1:-}"
verify_main_app_healthkit_profile "$release_temp/main-profile.plist"
verify_distribution_profile \
  "$live_activity_extension" "$LIVE_ACTIVITY_BUNDLE_ID" \
  "Live Activity extension" "$release_temp/extension-profile.plist" \
  "${LIVE_ACTIVITY_APP_STORE_PROFILE_UUID:-}" \
  "${IOS_DISTRIBUTION_CERTIFICATE_SHA1:-}"

extension_point=$(
  plist_value \
    "$live_activity_extension/Info.plist" \
    NSExtension:NSExtensionPointIdentifier
)
[[ "$extension_point" == "com.apple.widgetkit-extension" ]] || \
  fail "unexpected extension point $extension_point"

echo "==> Uploading without distribution or tester notification"
preupload_group_id_file="$release_temp/preupload-testflight-group-id"
if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then
  fastlane ios verify_internal_group \
    "api_key_path:$credential_json" \
    "bundle_id:$APP_BUNDLE_ID" \
    "group_name:$TESTFLIGHT_GROUP" \
    "group_id:$approved_group_id" \
    "expected_tester_id:$TESTFLIGHT_TESTER_ID" \
    "result_path:$preupload_group_id_file"
else
  fastlane ios verify_external_group \
    "api_key_path:$credential_json" \
    "bundle_id:$APP_BUNDLE_ID" \
    "group_name:$TESTFLIGHT_GROUP" \
    "group_id:$approved_group_id" \
    "result_path:$preupload_group_id_file"
fi
[[ "$(<"$preupload_group_id_file")" == "$approved_group_id" ]] || \
  fail "approved TestFlight audience changed before upload"
fastlane pilot upload \
  --api_key_path "$credential_json" \
  --app_identifier "$APP_BUNDLE_ID" \
  --app_platform ios \
  --ipa "$ipa" \
  --skip_waiting_for_build_processing false \
  --skip_submission true \
  --distribute_external false \
  --app_version "$EXPECTED_MARKETING_VERSION" \
  --build_number "$EXPECTED_BUILD_NUMBER" \
  --notify_external_testers false \
  --changelog "$TESTFLIGHT_CHANGELOG" \
  --wait_processing_interval 30

if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then
  echo "==> Verifying the exact internal-only TestFlight audience"
  fastlane ios verify_internal_build \
    "api_key_path:$credential_json" \
    "bundle_id:$APP_BUNDLE_ID" \
    "group_name:$TESTFLIGHT_GROUP" \
    "group_id:$approved_group_id" \
    "expected_tester_id:$TESTFLIGHT_TESTER_ID" \
    "version:$EXPECTED_MARKETING_VERSION" \
    "build_number:$EXPECTED_BUILD_NUMBER"
  echo "==> Verified internal TestFlight build $RELEASE_VERSION ($head_commit)"
  echo "    SHA-256: $artifact_sha256"
  exit 0
fi

echo "==> Associating the exact build with the approved immutable group ID"
fastlane ios associate_external_build \
  "api_key_path:$credential_json" \
  "bundle_id:$APP_BUNDLE_ID" \
  "group_name:$TESTFLIGHT_GROUP" \
  "group_id:$approved_group_id" \
  "version:$EXPECTED_MARKETING_VERSION" \
  "build_number:$EXPECTED_BUILD_NUMBER"

echo "==> Verifying the exclusive audience and notifying eligible testers"
echo "    If beta review is pending, re-run with TESTFLIGHT_NOTIFY_ONLY=yes and TESTFLIGHT_GROUP_ID=$approved_group_id after approval."
fastlane ios notify_external_build \
  "api_key_path:$credential_json" \
  "bundle_id:$APP_BUNDLE_ID" \
  "group_name:$TESTFLIGHT_GROUP" \
  "group_id:$approved_group_id" \
  "version:$EXPECTED_MARKETING_VERSION" \
  "build_number:$EXPECTED_BUILD_NUMBER" \
  "source_commit:$head_commit" \
  "notification_receipt_path:$NOTIFICATION_RECEIPT_PATH"

echo "==> Verified audience and notification receipt for $RELEASE_VERSION ($head_commit)"
echo "    SHA-256: $artifact_sha256"
