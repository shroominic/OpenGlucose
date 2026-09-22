#!/bin/sh
set -eu
umask 077

capture_script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
capture_root=$(CDPATH='' cd -P "$capture_script_dir/.." && pwd)
capture_app_package=${CBIO_CAPTURE_APP_PACKAGE:-com.openglucose.app.debug}
capture_app_version_code=29
capture_app_version_name=0.4.0-debug
capture_launch_activity=com.aidex.aidex_flutter.MainActivity
capture_expected_installed_sha=70547d756cae308d45cd76739e93ad3727225175fdd2a8cf8a7862cc1859eb4a
capture_expected_signer_sha=ad5e6dd01a944d2ea159d1bb1b1376de8a3962beaa95ddb0d7af513fe84ebcb5
capture_device_id=${DEVICE_ID:-}
capture_android_user=${ANDROID_USER_ID:-}
capture_context=${CBIO_DART_DEFINE_FROM_FILE:-}
capture_destination=${CAPTURE_DIR:-}
capture_build_timeout=${CBIO_BUILD_TIMEOUT_SECONDS:-900}
capture_operation_timeout=${CBIO_OPERATION_TIMEOUT_SECONDS:-30}
capture_radio_seconds=${CBIO_CAPTURE_TIMEOUT_SECONDS:-300}
capture_logcat_pid=
capture_prearmed_deadline_ms=
capture_radio_deadline_ms=

capture_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

capture_cleanup() {
  if [ -n "$capture_logcat_pid" ] && kill -0 "$capture_logcat_pid" 2>/dev/null; then
    kill "$capture_logcat_pid" 2>/dev/null || true
    sleep 0.1
    if kill -0 "$capture_logcat_pid" 2>/dev/null; then
      kill -KILL "$capture_logcat_pid" 2>/dev/null || true
    fi
    wait "$capture_logcat_pid" 2>/dev/null || true
  fi
}
trap capture_cleanup EXIT HUP INT TERM

capture_hex() {
  capture_hex_value=$1
  capture_hex_length=$2
  [ "${#capture_hex_value}" -eq "$capture_hex_length" ] || return 1
  case "$capture_hex_value" in *[!0-9a-f]*) return 1 ;; esac
}

capture_now() { date +%s; }
capture_monotonic_ms() {
  ruby -e 'puts((Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).floor)'
}

capture_run_limited() {
  capture_limit_ms=$1
  shift
  [ "$capture_limit_ms" -gt 0 ] || return 124
  ruby -e '
    budget = Integer(ARGV.shift) / 1000.0
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
    pid = Process.spawn(*ARGV, pgroup: true)
    status = nil
    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      if waited
        status = waited.last
        break
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        begin Process.kill("TERM", -pid); rescue Errno::ESRCH; end
        sleep 0.1
        begin Process.kill("KILL", -pid); rescue Errno::ESRCH; end
        begin Process.waitpid(pid); rescue Errno::ECHILD; end
        exit 124
      end
      sleep 0.02
    end
    exit(status.exitstatus || 128 + status.termsig)
  ' "$capture_limit_ms" "$@"
}

capture_deadline_remaining() {
  capture_deadline=$1
  capture_remaining=$((capture_deadline - $(capture_monotonic_ms)))
  [ "$capture_remaining" -gt 0 ] || return 124
  printf '%s\n' "$capture_remaining"
}

capture_run_prearmed() {
  capture_prearmed_remaining=$(capture_deadline_remaining "$capture_prearmed_deadline_ms") || return 124
  capture_operation_ms=$((capture_operation_timeout * 1000))
  if [ "$capture_prearmed_remaining" -lt "$capture_operation_ms" ]; then
    capture_operation_ms=$capture_prearmed_remaining
  fi
  capture_run_limited "$capture_operation_ms" "$@"
}

capture_run_build() {
  capture_build_remaining=$(capture_deadline_remaining "$capture_prearmed_deadline_ms") || return 124
  capture_run_limited "$capture_build_remaining" "$@"
}

capture_run_budgeted() {
  [ -n "$capture_radio_deadline_ms" ] || capture_die 'capture watchdog is unavailable'
  capture_budget_remaining=$(capture_deadline_remaining "$capture_radio_deadline_ms") || return 124
  capture_run_limited "$capture_budget_remaining" "$@"
}

capture_adb_command() {
  if [ -n "$capture_radio_deadline_ms" ]; then
    capture_run_budgeted "$capture_adb" -s "$capture_device_id" "$@"
  else
    capture_run_prearmed "$capture_adb" -s "$capture_device_id" "$@"
  fi
}

capture_require_current_user() {
  capture_current_user=$(capture_adb_command shell -n am get-current-user 2>/dev/null || true)
  capture_cr=$(printf '\r')
  case "$capture_current_user" in
    *"$capture_cr") capture_current_user=${capture_current_user%"$capture_cr"} ;;
  esac
  [ "$capture_current_user" = "$capture_android_user" ] ||
    capture_die 'current Android user does not match the selected capture user'
}

capture_require_owner_unlocked() {
  [ "$capture_app_package" = com.openglucose.app.debug.owner ] || return 0
  capture_owner_user_state=$(capture_adb_command shell -n am get-started-user-state 0 2>/dev/null || true)
  capture_cr=$(printf '\r')
  case "$capture_owner_user_state" in
    *"$capture_cr") capture_owner_user_state=${capture_owner_user_state%"$capture_cr"} ;;
  esac
  [ "$capture_owner_user_state" = RUNNING_UNLOCKED ] ||
    capture_die 'Android user 0 must be running and unlocked for Owner capture'
}

capture_grant() {
  capture_require_current_user
  capture_adb_command shell -n pm grant --user "$capture_android_user" \
    "$capture_app_package" "$1" >/dev/null
}

capture_run_as_publish() {
  capture_relative=$1
  capture_pending=$capture_relative.pending
  capture_require_current_user
  # Positional parameters expand in the remote shell, not on the host.
  # shellcheck disable=SC2016
  capture_adb_command shell -T run-as "$capture_app_package" \
    --user "$capture_android_user" sh -c \
    'set -eu; umask 077; cat >"$1"; sync "$1" 2>/dev/null || true; mv "$1" "$2"' \
    sh "$capture_pending" "$capture_relative" >/dev/null
}

capture_run_as_pull() {
  capture_relative=$1
  capture_output=$2
  capture_require_current_user
  if ! capture_adb_command exec-out run-as "$capture_app_package" \
    --user "$capture_android_user" cat "$capture_relative" >"$capture_output"; then
    chmod 600 "$capture_output" 2>/dev/null || true
    return 1
  fi
  chmod 600 "$capture_output"
}

capture_sha256() { LC_ALL=C shasum -a 256 "$1" | awk '{print $1}'; }
capture_file_bytes() { wc -c <"$1" | tr -d '[:space:]'; }

capture_validate_source() {
  capture_checked_revision=$(capture_run_prearmed git -C "$capture_root" rev-parse HEAD) ||
    capture_die 'source revision check exceeded the build-to-ARMED deadline'
  [ "$capture_checked_revision" = "$capture_source_revision" ] ||
    capture_die 'capture source revision changed after admission'
  capture_checked_status=$(capture_run_prearmed git -C "$capture_root" status --porcelain=v1 --untracked-files=all) ||
    capture_die 'source status check exceeded the build-to-ARMED deadline'
  case "$capture_checked_status" in
    '') ;;
    '?? docs/superpowers/cbio-offset4-evidence-report.md') ;;
    *) capture_die 'capture source worktree changed after admission' ;;
  esac
  [ "$(capture_sha256 "$capture_context")" = "$capture_context_sha" ] ||
    capture_die 'private capture context changed after admission'
}

[ -n "$capture_device_id" ] || capture_die 'DEVICE_ID is required'
[ -n "$capture_android_user" ] || capture_die 'ANDROID_USER_ID is required'
case "$capture_android_user" in
  *[!0-9]*|'') capture_die 'ANDROID_USER_ID must be a decimal integer' ;;
esac
case "$capture_android_user:$capture_app_package" in
  10:com.openglucose.app.debug) capture_application_id_suffix=.debug ;;
  0:com.openglucose.app.debug.owner) capture_application_id_suffix=.debug.owner ;;
  *) capture_die 'capture package is not authorized for the selected Android user' ;;
esac
[ -n "$capture_context" ] || capture_die 'CBIO_DART_DEFINE_FROM_FILE is required'
[ -n "$capture_destination" ] || capture_die 'CAPTURE_DIR is required'
case "$capture_build_timeout:$capture_operation_timeout:$capture_radio_seconds" in
  *[!0-9:]*|:*|*:) capture_die 'capture timeouts must be integers' ;;
esac
[ "$capture_build_timeout" -gt 0 ] || capture_die 'build timeout must be positive'
[ "$capture_operation_timeout" -gt 0 ] || capture_die 'operation timeout must be positive'
[ "$capture_radio_seconds" -gt 0 ] && [ "$capture_radio_seconds" -le 300 ] ||
  capture_die 'capture timeout must be between 1 and 300 seconds'
command -v ruby >/dev/null 2>&1 || capture_die 'ruby is required'
command -v shasum >/dev/null 2>&1 || capture_die 'shasum is required'
capture_adb=$(command -v adb 2>/dev/null || true)
[ -n "$capture_adb" ] || capture_die 'adb is required'
capture_flutter=$(command -v flutter 2>/dev/null || true)
[ -n "$capture_flutter" ] || capture_die 'flutter is required'
capture_aapt=$(command -v aapt 2>/dev/null || true)
capture_apksigner=$(command -v apksigner 2>/dev/null || true)
if [ -z "$capture_aapt" ] || [ -z "$capture_apksigner" ]; then
  capture_sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
  if [ -z "$capture_sdk" ] && [ -f "$capture_root/openhealth/android/local.properties" ]; then
    capture_sdk=$(sed -n 's/^sdk\.dir=//p' "$capture_root/openhealth/android/local.properties" | tail -n 1)
  fi
  if [ -n "$capture_sdk" ]; then
    [ -n "$capture_aapt" ] || capture_aapt=$(find "$capture_sdk/build-tools" -mindepth 2 -maxdepth 2 -type f -name aapt -print 2>/dev/null | sort -V | tail -n 1)
    [ -n "$capture_apksigner" ] || capture_apksigner=$(find "$capture_sdk/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner -print 2>/dev/null | sort -V | tail -n 1)
  fi
fi
[ -n "$capture_aapt" ] && [ -x "$capture_aapt" ] || capture_die 'aapt is required'
[ -n "$capture_apksigner" ] && [ -x "$capture_apksigner" ] || capture_die 'apksigner is required'
capture_prearmed_deadline_ms=$(( $(capture_monotonic_ms) + capture_build_timeout * 1000 ))

capture_run_prearmed ruby -rpathname -e '
  context, destination, root, uid_text = ARGV
  uid = Integer(uid_text)
  abort "context path" unless Pathname.new(context).absolute?
  abort "destination path" unless Pathname.new(destination).absolute?
  root = File.realpath(root)
  inside = ->(path) { path == root || path.start_with?(root + File::SEPARATOR) }
  context_stat = File.lstat(context)
  abort "context file" unless context_stat.file? && !context_stat.symlink?
  abort "context owner" unless context_stat.uid == uid
  abort "context mode" unless context_stat.mode & 0o777 == 0o600
  context_real = File.realpath(context)
  abort "context repository" if inside.call(context_real)
  context_parent = File.dirname(context)
  parent_stat = File.lstat(context_parent)
  abort "context parent" unless parent_stat.directory? && !parent_stat.symlink?
  abort "context parent owner" unless parent_stat.uid == uid
  abort "context parent mode" unless parent_stat.mode & 0o077 == 0
  abort "context parent symlink" unless File.realpath(context_parent) == File.expand_path(context_parent)
  begin
    File.lstat(destination)
    abort "destination exists"
  rescue Errno::ENOENT
  end
  destination_parent = File.dirname(destination)
  destination_parent_stat = File.lstat(destination_parent)
  abort "destination parent" unless destination_parent_stat.directory? && !destination_parent_stat.symlink?
  abort "destination parent owner" unless destination_parent_stat.uid == uid
  abort "destination parent mode" unless destination_parent_stat.mode & 0o077 == 0
  abort "destination parent symlink" unless
    File.realpath(destination_parent) == File.expand_path(destination_parent)
  destination_real = File.join(File.realpath(destination_parent), File.basename(destination))
  abort "destination repository" if inside.call(destination_real)
' "$capture_context" "$capture_destination" "$capture_root" "$(id -u)" ||
  capture_die 'private capture paths are invalid'

capture_context_sha=$(capture_sha256 "$capture_context")

capture_metadata=$(capture_run_prearmed ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  keys = %w[
    CBIO_VENDOR_STREAM_KEY_HEX CBIO_VENDOR_AUTH_MATERIAL_HEX
    CBIO_VENDOR_AUTH_TRIGGER_HEX CBIO_CAPTURE_RUN_ID
    CBIO_CAPTURE_START_NONCE CBIO_CAPTURE_ACK_NONCE CBIO_TARGET_DEVICE_ID
    CBIO_EXPECTED_SERIAL_HEX CBIO_LABEL_SHA256 CBIO_REPLAY_CONTEXT
    CBIO_RAW_START_INDEX CBIO_SOURCE_REVISION
  ]
  abort "invalid context shape" unless value.is_a?(Hash) && value.keys.sort == keys.sort
  abort "invalid vendor material" unless
    value["CBIO_VENDOR_STREAM_KEY_HEX"].match?(/\A[0-9a-fA-F]{32}\z/) &&
    value["CBIO_VENDOR_AUTH_MATERIAL_HEX"].match?(/\A[0-9a-fA-F]{32}\z/) &&
    value["CBIO_VENDOR_AUTH_TRIGGER_HEX"].match?(/\A[0-9a-fA-F]{10}\z/)
  abort "invalid run context" unless
    value["CBIO_CAPTURE_RUN_ID"].match?(/\A[0-9a-f]{32}\z/) &&
    value["CBIO_CAPTURE_START_NONCE"].match?(/\A[0-9a-f]{32}\z/) &&
    value["CBIO_CAPTURE_ACK_NONCE"].match?(/\A[0-9a-f]{32}\z/) &&
    value["CBIO_CAPTURE_START_NONCE"] != value["CBIO_CAPTURE_ACK_NONCE"] &&
    value["CBIO_TARGET_DEVICE_ID"].match?(/\A(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\z/) &&
    value["CBIO_EXPECTED_SERIAL_HEX"].match?(/\A[0-9a-f]{12}\z/) &&
    value["CBIO_LABEL_SHA256"].match?(/\A[0-9a-f]{64}\z/) &&
    value["CBIO_REPLAY_CONTEXT"] == "V1.1.6A" &&
    value["CBIO_RAW_START_INDEX"] == "1" &&
    value["CBIO_SOURCE_REVISION"].match?(/\A[0-9a-f]{40}\z/)
  puts value["CBIO_CAPTURE_RUN_ID"]
  puts value["CBIO_CAPTURE_START_NONCE"]
  puts value["CBIO_CAPTURE_ACK_NONCE"]
  puts value["CBIO_LABEL_SHA256"]
  puts value["CBIO_SOURCE_REVISION"]
  puts value["CBIO_VENDOR_AUTH_TRIGGER_HEX"].downcase
  puts value["CBIO_TARGET_DEVICE_ID"]
' "$capture_context") || capture_die 'capture context is invalid'

capture_run_id=$(printf '%s\n' "$capture_metadata" | sed -n '1p')
capture_start_nonce=$(printf '%s\n' "$capture_metadata" | sed -n '2p')
capture_ack_nonce=$(printf '%s\n' "$capture_metadata" | sed -n '3p')
capture_label_sha=$(printf '%s\n' "$capture_metadata" | sed -n '4p')
capture_source_revision=$(printf '%s\n' "$capture_metadata" | sed -n '5p')
capture_prompt_hex=$(printf '%s\n' "$capture_metadata" | sed -n '6p')
capture_target_id=$(printf '%s\n' "$capture_metadata" | sed -n '7p')
capture_actual_revision=$(capture_run_prearmed git -C "$capture_root" rev-parse HEAD) ||
  capture_die 'source revision preflight exceeded the build-to-ARMED deadline'
[ "$capture_source_revision" = "$capture_actual_revision" ] ||
  capture_die 'capture source revision does not match the worktree HEAD'
capture_source_status=$(capture_run_prearmed git -C "$capture_root" status --porcelain=v1 --untracked-files=all) ||
  capture_die 'source status preflight exceeded the build-to-ARMED deadline'
case "$capture_source_status" in
  '') ;;
  '?? docs/superpowers/cbio-offset4-evidence-report.md') ;;
  *) capture_die 'capture source worktree is not clean' ;;
esac
capture_require_current_user
capture_require_owner_unlocked

mkdir -m 700 "$capture_destination"
capture_quarantine=$capture_destination/quarantine
mkdir -m 700 "$capture_quarantine"
capture_log=$capture_destination/capture.log
: >"$capture_log"
chmod 600 "$capture_log"

capture_apk=$capture_root/openhealth/build/app/outputs/flutter-apk/app-debug.apk
capture_build_started=$(capture_now)
(
  cd "$capture_root/openhealth"
  capture_run_build env \
    OPENGLUCOSE_DEBUG_APPLICATION_ID_SUFFIX="$capture_application_id_suffix" \
    "$capture_flutter" build apk --debug --no-pub \
    --target integration_test/cbio_raw08_private_capture_test.dart \
    --target-platform android-arm64 \
    --dart-define-from-file="$capture_context" \
    --dart-define=CBIO_CAPTURE_STANDALONE=true \
    --dart-define=CBIO_CAPTURE_APP_PACKAGE="$capture_app_package"
) >>"$capture_log" 2>&1 || capture_die 'host-only standalone APK build failed or timed out'

capture_validate_source
[ -f "$capture_apk" ] || capture_die 'standalone APK was not produced'
capture_apk_mtime=$(capture_run_prearmed ruby -e 'puts File.mtime(ARGV.fetch(0)).to_i' "$capture_apk") ||
  capture_die 'standalone APK freshness check timed out'
[ "$capture_apk_mtime" -ge "$capture_build_started" ] || capture_die 'standalone APK is stale'
chmod 600 "$capture_apk"
capture_candidate_sha=$(capture_sha256 "$capture_apk")
capture_hex "$capture_candidate_sha" 64 || capture_die 'standalone APK digest is invalid'

capture_badging=$(capture_run_prearmed "$capture_aapt" dump badging "$capture_apk") ||
  capture_die 'standalone APK metadata preflight failed or timed out'
capture_candidate_package=$(printf '%s\n' "$capture_badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
capture_candidate_version_code=$(printf '%s\n' "$capture_badging" | sed -n "s/^package:.*versionCode='\([^']*\)'.*/\1/p")
capture_candidate_version_name=$(printf '%s\n' "$capture_badging" | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p")
capture_candidate_activity=$(printf '%s\n' "$capture_badging" | sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p")
[ "$capture_candidate_package" = "$capture_app_package" ] || capture_die 'standalone APK package mismatch'
[ "$capture_candidate_version_code" = "$capture_app_version_code" ] || capture_die 'standalone APK versionCode mismatch'
[ "$capture_candidate_version_name" = "$capture_app_version_name" ] || capture_die 'standalone APK versionName mismatch'
[ "$capture_candidate_activity" = "$capture_launch_activity" ] || capture_die 'standalone APK launch activity mismatch'

capture_signature_report=$(capture_run_prearmed "$capture_apksigner" verify --print-certs "$capture_apk") ||
  capture_die 'standalone APK signature preflight failed or timed out'
capture_candidate_signer=$(printf '%s\n' "$capture_signature_report" |
  sed -n 's/^Signer #1 certificate SHA-256 digest: //p' |
  tr '[:upper:]' '[:lower:]' | tr -d ':[:space:]')
[ "$capture_candidate_signer" = "$capture_expected_signer_sha" ] ||
  capture_die 'standalone APK signer mismatch'

if [ "$capture_app_package" = com.openglucose.app.debug.owner ]; then
  capture_owner_global_packages=$(capture_adb_command shell -n pm list packages -u "$capture_app_package") ||
    capture_die 'global Owner package absence check failed or timed out'
  [ -z "$capture_owner_global_packages" ] ||
    capture_die 'Owner package is already installed globally; first-install capture refused'
  capture_owner_user_packages=$(capture_adb_command shell -n pm list packages --user 0 "$capture_app_package") ||
    capture_die 'user-0 Owner package absence check failed or timed out'
  [ -z "$capture_owner_user_packages" ] ||
    capture_die 'Owner package is already installed for user 0; first-install capture refused'
else
  capture_installed_path_output=$(capture_adb_command shell -n pm path --user "$capture_android_user" "$capture_app_package") ||
    capture_die 'installed package path preflight failed or timed out'
  case "$capture_installed_path_output" in
    package:/data/app/*/base.apk) capture_installed_apk=${capture_installed_path_output#package:} ;;
    *) capture_die 'installed package path is invalid' ;;
  esac
  case "$capture_installed_apk" in
    *[!A-Za-z0-9_./=+~-]*|*/../*|*/./*) capture_die 'installed package path is unsafe' ;;
  esac
  capture_installed_dump=$(capture_adb_command shell -n dumpsys package "$capture_app_package") ||
    capture_die 'installed package version preflight failed or timed out'
  capture_installed_version_code=$(printf '%s\n' "$capture_installed_dump" |
    sed -n 's/^[[:space:]]*versionCode=\([0-9][0-9]*\).*/\1/p' | sort -u)
  capture_installed_version_name=$(printf '%s\n' "$capture_installed_dump" |
    sed -n 's/^[[:space:]]*versionName=\([^[:space:]]*\).*/\1/p' | sort -u)
  [ "$capture_installed_version_code" = "$capture_app_version_code" ] ||
    capture_die 'installed package versionCode mismatch'
  [ "$capture_installed_version_name" = "$capture_app_version_name" ] ||
    capture_die 'installed package versionName mismatch'
  capture_installed_sha_output=$(capture_adb_command shell -n sha256sum "$capture_installed_apk") ||
    capture_die 'installed package digest preflight failed or timed out'
  capture_installed_sha=$(printf '%s\n' "$capture_installed_sha_output" | awk 'NR == 1 {print $1}')
  [ "$capture_installed_sha" = "$capture_expected_installed_sha" ] ||
    capture_die 'installed package digest no longer matches the accepted receipt'
fi

capture_validate_source
[ "$(capture_sha256 "$capture_apk")" = "$capture_candidate_sha" ] ||
  capture_die 'standalone APK changed after preflight'
capture_require_current_user
capture_require_owner_unlocked
if [ "$capture_app_package" = com.openglucose.app.debug.owner ]; then
  capture_adb_command install --user 0 --no-streaming "$capture_apk" >>"$capture_log" 2>&1 ||
    capture_die 'single approved Owner package first-install failed or timed out'
else
  capture_adb_command install -r --user "$capture_android_user" --no-streaming "$capture_apk" >>"$capture_log" 2>&1 ||
    capture_die 'single approved package replacement failed or timed out'
fi

capture_deadline_remaining "$capture_prearmed_deadline_ms" >/dev/null ||
  capture_die 'build-to-ARMED deadline expired before logcat start'
"$capture_adb" -s "$capture_device_id" logcat -v raw 'flutter:I' '*:S' >>"$capture_log" 2>&1 &
capture_logcat_pid=$!
sleep 0.1
kill -0 "$capture_logcat_pid" 2>/dev/null || capture_die 'filtered logcat failed to start'

capture_validate_source
[ "$(capture_sha256 "$capture_apk")" = "$capture_candidate_sha" ] ||
  capture_die 'standalone APK changed before launch'
capture_require_current_user
capture_adb_command shell -n am start --user "$capture_android_user" -n \
  "$capture_app_package/$capture_launch_activity" >>"$capture_log" 2>&1 ||
  capture_die 'explicit selected-user activity launch failed or timed out'

capture_relative_root=files/gs1-private-capture/$capture_run_id
capture_armed_pending=$capture_quarantine/armed.json.pending
capture_armed_expected=$(printf '{"schemaVersion":1,"runId":"%s","state":"armed"}' "$capture_run_id")
while :; do
  if capture_run_as_pull "$capture_relative_root/armed.json" "$capture_armed_pending" 2>/dev/null; then
    capture_armed_actual=$(cat "$capture_armed_pending")
    rm -f "$capture_armed_pending"
    [ "$capture_armed_actual" = "$capture_armed_expected" ] ||
      capture_die 'private ARMED marker is invalid'
    break
  fi
  rm -f "$capture_armed_pending"
  [ "$(capture_monotonic_ms)" -lt "$capture_prearmed_deadline_ms" ] ||
    capture_die 'build-to-ARMED deadline expired before private ARMED marker'
  kill -0 "$capture_logcat_pid" 2>/dev/null ||
    capture_die 'filtered logcat exited before private ARMED marker'
  sleep 0.1
done

for capture_permission in \
  android.permission.BLUETOOTH_SCAN \
  android.permission.BLUETOOTH_CONNECT \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION
do
  capture_grant "$capture_permission"
done

capture_radio_deadline_ms=$(( $(capture_monotonic_ms) + capture_radio_seconds * 1000 ))
printf '{"runId":"%s","nonce":"%s"}' "$capture_run_id" "$capture_start_nonce" |
  capture_run_as_publish "$capture_relative_root/start.json" ||
  capture_die 'START publication exceeded the capture deadline'

capture_started="CBIO-CAPTURE-STARTED run=$capture_run_id"
while ! grep -Fqx "$capture_started" "$capture_log"; do
  [ "$(capture_monotonic_ms)" -lt "$capture_radio_deadline_ms" ] ||
    capture_die 'five-minute radio/capture/pull deadline expired before STARTED'
  if ! kill -0 "$capture_logcat_pid" 2>/dev/null && ! grep -Fqx "$capture_started" "$capture_log"; then
    capture_die 'filtered logcat exited before the capture started'
  fi
  sleep 0.1
done

capture_ready=
while [ -z "$capture_ready" ]; do
  capture_ready=$(grep -E '^CBIO-CAPTURE-READY ' "$capture_log" | tail -n 1 || true)
  [ -z "$capture_ready" ] || break
  [ "$(capture_monotonic_ms)" -lt "$capture_radio_deadline_ms" ] ||
    capture_die 'five-minute radio/capture/pull deadline expired before READY'
  if ! kill -0 "$capture_logcat_pid" 2>/dev/null; then
    capture_ready=$(grep -E '^CBIO-CAPTURE-READY ' "$capture_log" | tail -n 1 || true)
    [ -n "$capture_ready" ] || capture_die 'filtered logcat exited before private capture export'
  fi
  sleep 0.1
done

# Split the marker into fields without allowing host filenames to rewrite them.
set -f
# shellcheck disable=SC2086
set -- $capture_ready
set +f
[ "$#" -eq 16 ] || capture_die 'READY line has an invalid field count'
[ "$1" = CBIO-CAPTURE-READY ] || capture_die 'READY marker is invalid'
[ "$2" = "run=$capture_run_id" ] || capture_die 'READY run binding is invalid'
[ "$3" = full=full-records.json ] || capture_die 'READY full path is invalid'
capture_full_bytes=${4#full_bytes=}
capture_full_sha=${5#full_sha=}
[ "$6" = manifest=manifest.json ] || capture_die 'READY manifest path is invalid'
capture_manifest_bytes=${7#manifest_bytes=}
capture_manifest_sha=${8#manifest_sha=}
[ "$9" = prompt=auth-prompt-receipt.json ] || capture_die 'READY prompt path is invalid'
capture_prompt_bytes=${10#prompt_bytes=}
capture_prompt_sha=${11#prompt_sha=}
capture_outcome=${12#outcome=}
[ "${13}" = audit=command-audit.json ] || capture_die 'READY audit path is invalid'
capture_audit_bytes=${14#audit_bytes=}
capture_audit_sha=${15#audit_sha=}
[ "${16}" = ack=ack.json ] || capture_die 'READY ACK path is invalid'
case "$capture_full_bytes:$capture_manifest_bytes:$capture_prompt_bytes:$capture_audit_bytes" in
  *[!0-9:]*|0:*|*:0:*|*:0) capture_die 'READY byte lengths are invalid' ;;
esac
capture_hex "$capture_full_sha" 64 || capture_die 'READY full digest is invalid'
capture_hex "$capture_manifest_sha" 64 || capture_die 'READY manifest digest is invalid'
capture_hex "$capture_prompt_sha" 64 || capture_die 'READY prompt digest is invalid'
capture_hex "$capture_audit_sha" 64 || capture_die 'READY audit digest is invalid'
case "$capture_outcome" in
  contiguous_prefix_tail_unproven|contiguous_prefix_cut_off|authenticated_query_no_records) ;;
  *) capture_die 'READY outcome is invalid' ;;
esac

capture_full_pending=$capture_quarantine/full-records.json.pending
capture_manifest_pending=$capture_quarantine/manifest.json.pending
capture_prompt_pending=$capture_quarantine/auth-prompt-receipt.json.pending
capture_audit_pending=$capture_quarantine/command-audit.json.pending
capture_run_as_pull "$capture_relative_root/full-records.json" "$capture_full_pending" ||
  capture_die 'full-record pull exceeded the capture deadline'
capture_run_as_pull "$capture_relative_root/manifest.json" "$capture_manifest_pending" ||
  capture_die 'manifest pull exceeded the capture deadline'
capture_run_as_pull "$capture_relative_root/auth-prompt-receipt.json" "$capture_prompt_pending" ||
  capture_die 'prompt pull exceeded the capture deadline'
capture_run_as_pull "$capture_relative_root/command-audit.json" "$capture_audit_pending" ||
  capture_die 'command-audit pull exceeded the capture deadline'

[ "$(capture_file_bytes "$capture_full_pending")" = "$capture_full_bytes" ] ||
  capture_die 'full-record byte length changed during pull'
[ "$(capture_sha256 "$capture_full_pending")" = "$capture_full_sha" ] ||
  capture_die 'full-record digest changed during pull'
[ "$(capture_file_bytes "$capture_manifest_pending")" = "$capture_manifest_bytes" ] ||
  capture_die 'manifest byte length changed during pull'
[ "$(capture_sha256 "$capture_manifest_pending")" = "$capture_manifest_sha" ] ||
  capture_die 'manifest digest changed during pull'
[ "$(capture_file_bytes "$capture_prompt_pending")" = "$capture_prompt_bytes" ] ||
  capture_die 'auth-prompt receipt length changed during pull'
[ "$(capture_sha256 "$capture_prompt_pending")" = "$capture_prompt_sha" ] ||
  capture_die 'auth-prompt receipt digest changed during pull'
[ "$(capture_file_bytes "$capture_audit_pending")" = "$capture_audit_bytes" ] ||
  capture_die 'command-audit length changed during pull'
[ "$(capture_sha256 "$capture_audit_pending")" = "$capture_audit_sha" ] ||
  capture_die 'command-audit digest changed during pull'

ruby -rjson -e '
  full_path, manifest_path, prompt_path, audit_path, run, revision, label,
    full_sha, full_bytes, prompt_sha, audit_sha, audit_bytes, outcome,
    prompt_hex, target, package = ARGV
  full = JSON.parse(File.read(full_path))
  manifest = JSON.parse(File.read(manifest_path))
  prompt = JSON.parse(File.read(prompt_path))
  audit = JSON.parse(File.read(audit_path))
  exact = ->(value, keys) {
    value.is_a?(Hash) && value.keys.sort == keys.sort
  }
  hex64 = ->(value) { value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/) }
  integer = ->(value) { value.is_a?(Integer) }

  prompt_keys = %w[matchCount maskedBytesHex observed runId schemaVersion]
  abort "prompt shape" unless exact.call(prompt, prompt_keys)
  abort "prompt binding" unless prompt["schemaVersion"] == 1 && prompt["runId"] == run &&
    [true, false].include?(prompt["observed"]) && integer.call(prompt["matchCount"]) &&
    prompt["matchCount"] >= 0
  if prompt["observed"]
    abort "prompt match" unless prompt["matchCount"] >= 1 && prompt["maskedBytesHex"] == prompt_hex
  else
    abort "prompt absence" unless prompt["matchCount"] == 0 && prompt["maskedBytesHex"].nil?
  end

  audit_keys = %w[
    attemptedFrameSha256 commandSequenceComplete runId schemaVersion
    successfulFrameSha256 writeGateFailed
  ]
  abort "audit shape" unless exact.call(audit, audit_keys)
  attempted = audit["attemptedFrameSha256"]
  successful = audit["successfulFrameSha256"]
  abort "audit binding" unless audit["schemaVersion"] == 1 && audit["runId"] == run &&
    attempted.is_a?(Array) && successful.is_a?(Array) && attempted.length == 3 &&
    successful.length == 3 && attempted.all? { |digest| hex64.call(digest) } &&
    successful.all? { |digest| hex64.call(digest) } && attempted == successful &&
    audit["writeGateFailed"] == false && audit["commandSequenceComplete"] == true

  manifest_keys = %w[
    anchorPresent artifactBytes artifactSha256 attemptedWriteCount
    authPromptMatchCount authPromptObserved authPromptReceiptSha256 bootstrap
    captureCompleteness commandAuditBytes commandAuditSha256
    commandSequenceComplete driverError driverStage firstIndex historyWindowClosed
    identityMatched indexGapCount labelSha256 lastIndex packageId prefixValid
    rawTimeBreakCount rawTimeSegmentCount recordCount replayContext retainedTailProof
    runId schemaVersion sourceRevision state successfulWriteCount topologyMatched
    versionEvidence
  ]
  abort "manifest shape" unless exact.call(manifest, manifest_keys)
  abort "manifest binding" unless
    manifest["schemaVersion"] == 1 && manifest["runId"] == run &&
    manifest["sourceRevision"] == revision &&
    manifest["packageId"] == package &&
    manifest["replayContext"] == "V1.1.6A" && manifest["labelSha256"] == label &&
    manifest["artifactSha256"] == full_sha && manifest["artifactBytes"] == Integer(full_bytes) &&
    manifest["authPromptReceiptSha256"] == prompt_sha &&
    manifest["commandAuditSha256"] == audit_sha &&
    manifest["commandAuditBytes"] == Integer(audit_bytes) &&
    manifest["captureCompleteness"] == outcome &&
    manifest["retainedTailProof"] == "unavailable_no_protocol_watermark"
  abort "manifest prompt" unless
    manifest["authPromptObserved"] == prompt["observed"] &&
    manifest["authPromptMatchCount"] == prompt["matchCount"] &&
    manifest["versionEvidence"] == (prompt["observed"] ?
      "incoming_auth_prompt_exact_match" : "declared_context_only")
  abort "manifest command" unless
    manifest["identityMatched"] == true && manifest["topologyMatched"] == true &&
    manifest["attemptedWriteCount"] == 3 && manifest["successfulWriteCount"] == 3 &&
    manifest["commandSequenceComplete"] == true &&
    manifest["attemptedWriteCount"] == attempted.length &&
    manifest["successfulWriteCount"] == successful.length
  abort "manifest driver" unless
    %w[connecting authenticating syncing ready].include?(manifest["driverStage"]) &&
    manifest["driverError"].nil?
  abort "manifest types" unless
    [true, false].include?(manifest["prefixValid"]) &&
    [true, false].include?(manifest["historyWindowClosed"]) &&
    manifest["anchorPresent"] == false && manifest["bootstrap"] == "fresh" &&
    manifest["state"] == "observing" && manifest["prefixValid"] == true &&
    %w[recordCount indexGapCount rawTimeBreakCount rawTimeSegmentCount].all? { |key|
      integer.call(manifest[key]) && manifest[key] >= 0
    } && ["firstIndex", "lastIndex"].all? { |key| manifest[key].nil? || integer.call(manifest[key]) }

  full_keys = %w[bootstrap captureId driverId profile records schemaVersion sensorKey state]
  full_keys += %w[currentCheckpoint firstObservation]
  abort "full shape" unless exact.call(full, full_keys)
  abort "full binding" unless full["schemaVersion"] == 1 && full["driverId"] == "cbio" &&
    full["profile"] == "raw08-observed" && full["sensorKey"] == target &&
    full["captureId"] == run && exact.call(full["bootstrap"], ["kind"]) &&
    full["bootstrap"]["kind"] == "fresh" && full["records"].is_a?(Array) &&
    full["records"].length <= 65_535 && manifest["state"] == full["state"]
  rows = full["records"]
  rows.each do |row|
    abort "full row" unless row.is_a?(Array) && row.length == 7 &&
      row.each_with_index.all? { |value, index|
        integer.call(value) && value >= (index.zero? ? 1 : 0) &&
          value <= (index == 1 ? 0xffff_ffff : 0xffff)
      }
  end
  abort "record count" unless manifest["recordCount"] == rows.length
  abort "observing state" unless full["state"] == "observing"
  abort "observing empty" if rows.empty?
  indexes = rows.map(&:first)
  gaps = indexes.each_cons(2).count { |left, right| right != left + 1 }
  breaks = rows.map { |row| row[1] }.each_cons(2).count { |left, right| right - left != 60 }
  checkpoint = JSON.parse(full["currentCheckpoint"])
  abort "checkpoint" unless exact.call(checkpoint, %w[index rawTime sensorKey version]) &&
    checkpoint["version"] == 1 && checkpoint["sensorKey"] == target &&
    checkpoint["index"] == rows.last[0] && checkpoint["rawTime"] == rows.last[1]
  abort "first observation" unless full["firstObservation"] == rows.first.take(2)
  abort "observing summary" unless indexes.first == 1 && gaps == 0 &&
    manifest["prefixValid"] == true && manifest["firstIndex"] == indexes.first &&
    manifest["lastIndex"] == indexes.last && manifest["indexGapCount"] == gaps &&
    manifest["rawTimeBreakCount"] == breaks && manifest["rawTimeSegmentCount"] == breaks + 1
  expected = manifest["historyWindowClosed"] ?
    "contiguous_prefix_tail_unproven" : "contiguous_prefix_cut_off"
  abort "observing completeness" unless manifest["captureCompleteness"] == expected
' "$capture_full_pending" "$capture_manifest_pending" "$capture_prompt_pending" \
  "$capture_audit_pending" "$capture_run_id" "$capture_source_revision" \
  "$capture_label_sha" "$capture_full_sha" "$capture_full_bytes" \
  "$capture_prompt_sha" "$capture_audit_sha" "$capture_audit_bytes" \
  "$capture_outcome" "$capture_prompt_hex" "$capture_target_id" \
  "$capture_app_package" ||
  capture_die 'capture artifact validation failed'

printf '{"runId":"%s","nonce":"%s","manifestSha256":"%s"}' \
  "$capture_run_id" "$capture_ack_nonce" "$capture_manifest_sha" |
  capture_run_as_publish "$capture_relative_root/ack.json" ||
  capture_die 'ACK publication exceeded the capture deadline'

capture_complete="CBIO-CAPTURE-COMPLETE run=$capture_run_id"
while ! grep -Fqx "$capture_complete" "$capture_log"; do
  [ "$(capture_monotonic_ms)" -lt "$capture_radio_deadline_ms" ] ||
    capture_die 'five-minute radio/capture/pull deadline expired before COMPLETE'
  if ! kill -0 "$capture_logcat_pid" 2>/dev/null && ! grep -Fqx "$capture_complete" "$capture_log"; then
    capture_die 'filtered logcat exited before exact COMPLETE marker'
  fi
  sleep 0.1
done

mv "$capture_full_pending" "$capture_destination/full-records.json"
mv "$capture_manifest_pending" "$capture_destination/manifest.json"
mv "$capture_prompt_pending" "$capture_destination/auth-prompt-receipt.json"
mv "$capture_audit_pending" "$capture_destination/command-audit.json"
chmod 600 "$capture_destination/full-records.json" \
  "$capture_destination/manifest.json" \
  "$capture_destination/auth-prompt-receipt.json" \
  "$capture_destination/command-audit.json"
rmdir "$capture_quarantine"

printf 'CBIO private capture preserved: outcome=%s\n' "$capture_outcome"
