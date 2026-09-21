#!/bin/sh
set -eu
umask 077

capture_script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
capture_root=$(CDPATH='' cd -P "$capture_script_dir/.." && pwd)
capture_app_package=com.openglucose.app.debug
capture_device_id=${DEVICE_ID:-}
capture_android_user=${ANDROID_USER_ID:-}
capture_context=${CBIO_DART_DEFINE_FROM_FILE:-}
capture_destination=${CAPTURE_DIR:-}
capture_build_timeout=${CBIO_BUILD_TIMEOUT_SECONDS:-900}
capture_radio_seconds=300
capture_flutter_pid=

capture_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

capture_cleanup() {
  if [ -n "$capture_flutter_pid" ] && kill -0 "$capture_flutter_pid" 2>/dev/null; then
    kill "$capture_flutter_pid" 2>/dev/null || true
    wait "$capture_flutter_pid" 2>/dev/null || true
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

capture_require_current_user() {
  capture_current_user=$(
    "$capture_adb" -s "$capture_device_id" shell -n am get-current-user 2>/dev/null || true
  )
  capture_cr=$(printf '\r')
  case "$capture_current_user" in
    *"$capture_cr") capture_current_user=${capture_current_user%"$capture_cr"} ;;
  esac
  [ "$capture_current_user" = "$capture_android_user" ] ||
    capture_die 'current Android user does not match the selected capture user'
}

capture_grant() {
  capture_require_current_user
  "$capture_adb" -s "$capture_device_id" shell -n pm grant \
    --user "$capture_android_user" "$capture_app_package" "$1" >/dev/null
}

capture_run_as_upload() {
  capture_relative=$1
  capture_require_current_user
  "$capture_adb" -s "$capture_device_id" shell -T run-as \
    "$capture_app_package" --user "$capture_android_user" \
    tee "$capture_relative" >/dev/null
}

capture_run_as_pull() {
  capture_relative=$1
  capture_output=$2
  capture_require_current_user
  "$capture_adb" -s "$capture_device_id" exec-out run-as \
    "$capture_app_package" --user "$capture_android_user" \
    cat "$capture_relative" >"$capture_output"
  chmod 600 "$capture_output"
}

capture_sha256() { LC_ALL=C shasum -a 256 "$1" | awk '{print $1}'; }
capture_file_bytes() { wc -c <"$1" | tr -d '[:space:]'; }

[ -n "$capture_device_id" ] || capture_die 'DEVICE_ID is required'
[ -n "$capture_android_user" ] || capture_die 'ANDROID_USER_ID is required'
case "$capture_android_user" in
  *[!0-9]*|'') capture_die 'ANDROID_USER_ID must be a decimal integer' ;;
esac
[ "$capture_android_user" = 10 ] ||
  capture_die 'this capture is authorized only for Android user 10'
[ -f "$capture_context" ] || capture_die 'CBIO_DART_DEFINE_FROM_FILE must name a file'
[ -n "$capture_destination" ] || capture_die 'CAPTURE_DIR is required'
case "$capture_build_timeout" in
  *[!0-9]*|'') capture_die 'CBIO_BUILD_TIMEOUT_SECONDS must be an integer' ;;
esac
[ "$capture_build_timeout" -gt 0 ] || capture_die 'build timeout must be positive'

capture_context_mode=$(stat -f %Lp "$capture_context" 2>/dev/null || stat -c %a "$capture_context")
[ "$capture_context_mode" = 600 ] || capture_die 'capture context must have mode 0600'
command -v ruby >/dev/null 2>&1 || capture_die 'ruby is required'
command -v shasum >/dev/null 2>&1 || capture_die 'shasum is required'
capture_adb=$(command -v adb 2>/dev/null || true)
[ -n "$capture_adb" ] || capture_die 'adb is required'
command -v flutter >/dev/null 2>&1 || capture_die 'flutter is required'

capture_metadata=$(ruby -rjson -e '
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
' "$capture_context") || capture_die 'capture context is invalid'

capture_run_id=$(printf '%s\n' "$capture_metadata" | sed -n '1p')
capture_start_nonce=$(printf '%s\n' "$capture_metadata" | sed -n '2p')
capture_ack_nonce=$(printf '%s\n' "$capture_metadata" | sed -n '3p')
capture_label_sha=$(printf '%s\n' "$capture_metadata" | sed -n '4p')
capture_source_revision=$(printf '%s\n' "$capture_metadata" | sed -n '5p')
capture_actual_revision=$(git -C "$capture_root" rev-parse HEAD)
[ "$capture_source_revision" = "$capture_actual_revision" ] ||
  capture_die 'capture source revision does not match the worktree HEAD'
capture_require_current_user

[ ! -e "$capture_destination" ] || capture_die 'CAPTURE_DIR already exists'
mkdir -m 700 "$capture_destination"
capture_log=$capture_destination/flutter.log
: >"$capture_log"
chmod 600 "$capture_log"

(
  cd "$capture_root/openhealth"
  flutter test --no-pub integration_test/cbio_raw08_private_capture_test.dart \
    -d "$capture_device_id" --dart-define-from-file="$capture_context"
) >"$capture_log" 2>&1 &
capture_flutter_pid=$!

capture_build_deadline=$(( $(capture_now) + capture_build_timeout ))
capture_armed="CBIO-CAPTURE-ARMED run=$capture_run_id start=start.json"
while ! grep -Fqx "$capture_armed" "$capture_log"; do
  if ! kill -0 "$capture_flutter_pid" 2>/dev/null; then
    wait "$capture_flutter_pid" 2>/dev/null || true
    capture_die 'Flutter exited before the capture was armed'
  fi
  [ "$(capture_now)" -lt "$capture_build_deadline" ] ||
    capture_die 'Flutter build/install/start timeout expired before ARMED'
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

capture_relative_root=files/gs1-private-capture/$capture_run_id
capture_radio_deadline=$(( $(capture_now) + capture_radio_seconds ))
printf '{"runId":"%s","nonce":"%s"}' \
  "$capture_run_id" "$capture_start_nonce" |
  capture_run_as_upload "$capture_relative_root/start.json"

capture_started="CBIO-CAPTURE-STARTED run=$capture_run_id"
while ! grep -Fqx "$capture_started" "$capture_log"; do
  [ "$(capture_now)" -lt "$capture_radio_deadline" ] ||
    capture_die 'five-minute radio/capture/pull deadline expired before STARTED'
  kill -0 "$capture_flutter_pid" 2>/dev/null ||
    capture_die 'Flutter exited before the capture started'
  sleep 0.1
done

capture_ready=
while [ -z "$capture_ready" ]; do
  capture_ready=$(grep -E '^CBIO-CAPTURE-READY ' "$capture_log" | tail -n 1 || true)
  [ -z "$capture_ready" ] || break
  [ "$(capture_now)" -lt "$capture_radio_deadline" ] ||
    capture_die 'five-minute radio/capture/pull deadline expired before READY'
  kill -0 "$capture_flutter_pid" 2>/dev/null ||
    capture_die 'Flutter exited before private capture export'
  sleep 0.1
done

set -- $capture_ready
[ "$#" -eq 13 ] || capture_die 'READY line has an invalid field count'
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
[ "${13}" = ack=ack.json ] || capture_die 'READY ACK path is invalid'
case "$capture_full_bytes:$capture_manifest_bytes:$capture_prompt_bytes" in
  *[!0-9:]*|:*|*:) capture_die 'READY byte lengths are invalid' ;;
esac
capture_hex "$capture_full_sha" 64 || capture_die 'READY full digest is invalid'
capture_hex "$capture_manifest_sha" 64 || capture_die 'READY manifest digest is invalid'
capture_hex "$capture_prompt_sha" 64 || capture_die 'READY prompt digest is invalid'
case "$capture_outcome" in
  contiguous_prefix_tail_unproven|contiguous_prefix_cut_off|authenticated_query_no_records|no_authenticated_raw_query) ;;
  *) capture_die 'READY outcome is invalid' ;;
esac

capture_full_pending=$capture_destination/full-records.json.pending
capture_manifest_pending=$capture_destination/manifest.json.pending
capture_prompt_pending=$capture_destination/auth-prompt-receipt.json.pending
capture_run_as_pull "$capture_relative_root/full-records.json" "$capture_full_pending"
capture_run_as_pull "$capture_relative_root/manifest.json" "$capture_manifest_pending"
capture_run_as_pull "$capture_relative_root/auth-prompt-receipt.json" "$capture_prompt_pending"
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

ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  expected = %w[
    anchorPresent artifactBytes artifactSha256 attemptedWriteCount
    authPromptMatchCount authPromptObserved authPromptReceiptSha256 bootstrap
    captureCompleteness commandSequenceComplete driverError driverStage
    firstIndex historyWindowClosed identityMatched indexGapCount labelSha256
    lastIndex packageId prefixValid rawTimeBreakCount rawTimeSegmentCount
    recordCount replayContext retainedTailProof runId schemaVersion
    sourceRevision state successfulWriteCount topologyMatched versionEvidence
  ]
  abort "manifest shape" unless value.is_a?(Hash) && value.keys.sort == expected.sort
  abort "manifest binding" unless
    value["schemaVersion"] == 1 && value["runId"] == ARGV.fetch(1) &&
    value["sourceRevision"] == ARGV.fetch(2) &&
    value["packageId"] == "com.openglucose.app.debug" &&
    value["replayContext"] == "V1.1.6A" &&
    value["labelSha256"] == ARGV.fetch(3) &&
    value["artifactSha256"] == ARGV.fetch(4) &&
    value["artifactBytes"] == ARGV.fetch(5).to_i &&
    value["captureCompleteness"] == ARGV.fetch(6) &&
    value["retainedTailProof"] == "unavailable_no_protocol_watermark" &&
    value["authPromptReceiptSha256"] == ARGV.fetch(7) &&
    [true, false].include?(value["authPromptObserved"]) &&
    value["authPromptMatchCount"].is_a?(Integer) &&
    value["authPromptMatchCount"] >= 0 &&
    value["versionEvidence"] == (value["authPromptObserved"] ?
      "incoming_auth_prompt_exact_match" : "declared_context_only")
' "$capture_manifest_pending" "$capture_run_id" "$capture_source_revision" \
  "$capture_label_sha" "$capture_full_sha" "$capture_full_bytes" "$capture_outcome" \
  "$capture_prompt_sha" ||
  capture_die 'manifest validation failed'

ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "prompt receipt shape" unless value.is_a?(Hash) &&
    value.keys.sort == %w[matchCount maskedBytesHex observed runId schemaVersion].sort &&
    value["schemaVersion"] == 1 && value["runId"] == ARGV.fetch(1) &&
    [true, false].include?(value["observed"]) &&
    value["matchCount"].is_a?(Integer) && value["matchCount"] >= 0
  if value["observed"]
    abort "prompt receipt match" unless value["matchCount"] >= 1 &&
      value["maskedBytesHex"].is_a?(String) &&
      value["maskedBytesHex"].match?(/\A[0-9a-f]{10}\z/)
  else
    abort "prompt receipt absence" unless value["matchCount"] == 0 &&
      value["maskedBytesHex"].nil?
  end
' "$capture_prompt_pending" "$capture_run_id" ||
  capture_die 'auth-prompt receipt validation failed'

mv "$capture_full_pending" "$capture_destination/full-records.json"
mv "$capture_manifest_pending" "$capture_destination/manifest.json"
mv "$capture_prompt_pending" "$capture_destination/auth-prompt-receipt.json"
chmod 600 "$capture_destination/full-records.json" \
  "$capture_destination/manifest.json" \
  "$capture_destination/auth-prompt-receipt.json"

[ "$(capture_now)" -lt "$capture_radio_deadline" ] ||
  capture_die 'five-minute radio/capture/pull deadline expired before ACK'
printf '{"runId":"%s","nonce":"%s","manifestSha256":"%s"}' \
  "$capture_run_id" "$capture_ack_nonce" "$capture_manifest_sha" |
  capture_run_as_upload "$capture_relative_root/ack.json"

while kill -0 "$capture_flutter_pid" 2>/dev/null; do
  [ "$(capture_now)" -lt "$capture_radio_deadline" ] ||
    capture_die 'five-minute radio/capture/pull deadline expired before Flutter exit'
  sleep 0.1
done
set +e
wait "$capture_flutter_pid"
capture_flutter_status=$?
set -e
capture_flutter_pid=
[ "$capture_flutter_status" -eq 0 ] || capture_die 'capture harness reported failure'

printf 'CBIO private capture preserved: outcome=%s\n' "$capture_outcome"
