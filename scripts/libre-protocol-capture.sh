#!/bin/sh
set -eu

umask 077

capture_script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
capture_repository_root=$(CDPATH='' cd -P "$capture_script_dir/.." && pwd)
capture_libre_package=$capture_repository_root/packages/cgm_libre2

capture_default_root=${OPENGLUCOSE_CAPTURE_ROOT:-${TMPDIR:-/tmp}/openglucose-protocol-captures}
capture_default_package=com.openglucose.app.debug
capture_requested_profile=${OPENGLUCOSE_CAPTURE_PROFILE:-libre}
case "$capture_requested_profile" in
  libre | yuwell_anytime_passive) ;;
  *)
    printf 'error: unknown OPENGLUCOSE_CAPTURE_PROFILE\n' >&2
    exit 1
    ;;
esac
capture_requested_live_aidex=${OPENGLUCOSE_CAPTURE_LIVE_AIDEX:-false}
case "$capture_requested_live_aidex" in
  true | false) ;;
  *)
    printf 'error: OPENGLUCOSE_CAPTURE_LIVE_AIDEX must be true or false\n' >&2
    exit 1
    ;;
esac
capture_adb=
capture_serial=
capture_android_user_id=
capture_expected_android_user_id=
capture_session=
capture_cleanup_pid=
capture_cleanup_fingerprint=
capture_cleanup_session=
capture_grant_temp_dir=
capture_arm_cleanup_device=false
capture_arm_lease_owned=false
capture_arm_lease_directory=files/protocol-captures/nfc-rf-transaction.lease
capture_arm_lease_owner_file=
capture_collect_temp_dir=
capture_collect_destination=
capture_collect_hash_destination=
capture_collect_cleanup_destination=false
capture_source=
capture_rebind_workspace=
capture_rebind_workspace_owned=false
capture_rebind_workspace_marker=
capture_rebind_backup_path=
capture_rebind_pending_path=
capture_rebind_promotion_started=false
capture_rebind_promoted=false
capture_rebind_committed=false

capture_usage() {
  cat <<'EOF'
Passive Android capture for an operator-owned device.

Usage:
  libre-protocol-capture.sh doctor [--output-root DIR] [--package ID]
  libre-protocol-capture.sh start [--output-root DIR] [--package ID]
  libre-protocol-capture.sh verify-app-ready --session DIR
  libre-protocol-capture.sh verify-target-observation --session DIR --ack-reference-e007-target-unverified
  libre-protocol-capture.sh snapshot --session DIR --label LABEL
  libre-protocol-capture.sh arm-target-unverified-nfc-probe --session DIR --ack-r3-target-unverified
  libre-protocol-capture.sh arm-target-unverified-nfc-probe-from-verified-target --session DIR --source-session DIR --ack-r3-target-unverified --ack-reuse-verified-target
  libre-protocol-capture.sh disarm-target-unverified-nfc-probe --session DIR
  libre-protocol-capture.sh arm-target-unverified-gen1-fram-read --session DIR --ack-r3-gen1-fram-read
  libre-protocol-capture.sh disarm-target-unverified-gen1-fram-read --session DIR
  libre-protocol-capture.sh collect-gen1-fram-capture --session DIR
  libre-protocol-capture.sh arm-target-unverified-gen1-activation --session DIR --ack-r3-gen1-activation
  libre-protocol-capture.sh disarm-target-unverified-gen1-activation --session DIR
  libre-protocol-capture.sh bugreport --session DIR
  libre-protocol-capture.sh stop --session DIR [--label LABEL] [--bugreport]

Capture and collection commands read diagnostics only. Explicit arm/disarm
commands create or remove only the fixed app-private grant files. The harness
does not install or launch an app, change Bluetooth/NFC settings, scan,
bond/unbond, clear logs, or contact a sensor. Set ANDROID_SERIAL when more than
one ADB device is connected.
EOF
}

capture_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

capture_require_command() {
  command -v "$1" >/dev/null 2>&1 || capture_die "required command is missing: $1"
}

capture_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    capture_die 'shasum or sha256sum is required'
  fi
}

capture_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    capture_die 'shasum or sha256sum is required'
  fi
}

capture_validate_package() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$' ||
    capture_die 'package must be a dotted Android application ID'
}

capture_validate_label() {
  case "$1" in
    00-baseline-phone | 01-app-idle | 02-advertisement-observed | 03-nfc-detected | \
      04-patch-metadata | 05-activation-requested | 06-activation-response | \
      07-ble-connected | 08-native-pair-prompt | 09-bonded | \
      10-services-discovered | 11-auth-challenge | 12-auth-session | \
      13-stream-subscribed | 14-warmup | 15-first-composite | 16-first-reading | \
      17-disconnect-recovery | E01-native-pair-failed | \
      E02-service-discovery-timeout | E03-auth-length-mismatch | \
      E04-auth-integrity-failed | E05-stream-fragment-timeout | \
      E06-device-disconnected | E07-unexpected-write | E08-unknown-service-map | \
      E09-sensor-state-mismatch | E10-capture-gap | phase-99-final)
      ;;
    *)
      capture_die 'label is not in the neutral runbook allowlist'
      ;;
  esac
}

capture_host_monotonic_nanos() {
  ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)'
}

capture_canonical_candidate() {
  capture_path=$1
  case "$capture_path" in
    /*) ;;
    *) capture_die 'output and session paths must be absolute' ;;
  esac
  case "$capture_path" in
    */../* | */.. | */./* | */.) capture_die 'dot path components are not allowed' ;;
  esac

  capture_probe=$capture_path
  capture_suffix=
  while [ ! -e "$capture_probe" ]; do
    capture_name=${capture_probe##*/}
    capture_suffix=/$capture_name$capture_suffix
    capture_parent=${capture_probe%/*}
    [ -n "$capture_parent" ] || capture_parent=/
    [ "$capture_parent" != "$capture_probe" ] || capture_die 'cannot resolve output path'
    capture_probe=$capture_parent
  done
  [ -d "$capture_probe" ] || capture_die 'the nearest existing output ancestor is not a directory'
  capture_physical=$(CDPATH='' cd -P "$capture_probe" && pwd)
  printf '%s%s\n' "$capture_physical" "$capture_suffix"
}

capture_require_outside_git() {
  capture_candidate=$(capture_canonical_candidate "$1")
  capture_require_command git
  capture_probe=$capture_candidate
  while [ ! -e "$capture_probe" ]; do
    capture_probe=${capture_probe%/*}
    [ -n "$capture_probe" ] || capture_probe=/
  done
  # Ignore ambient hook GIT_* so -C discovery is path-local.
  capture_inside_work=$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
    git -C "$capture_probe" rev-parse --is-inside-work-tree 2>/dev/null || printf 'false'
  )
  capture_inside_git=$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
    git -C "$capture_probe" rev-parse --is-inside-git-dir 2>/dev/null || printf 'false'
  )
  [ "$capture_inside_work" != true ] || capture_die 'capture output must be outside every Git worktree'
  [ "$capture_inside_git" != true ] || capture_die 'capture output must be outside every Git directory'
  printf '%s\n' "$capture_candidate"
}

capture_prepare_root() {
  capture_root=$(capture_require_outside_git "$1")
  [ "$capture_root" != / ] || capture_die 'filesystem root is not an allowed capture directory'
  mkdir -p "$capture_root"
  chmod 700 "$capture_root"
  capture_root=$(capture_require_outside_git "$capture_root")
  printf '%s\n' "$capture_root"
}

capture_select_device() {
  capture_require_command adb
  capture_adb=$(command -v adb)
  if [ -n "${ANDROID_SERIAL:-}" ]; then
    capture_serial=$ANDROID_SERIAL
  else
    capture_devices=$($capture_adb devices 2>/dev/null | awk 'NR > 1 && NF >= 2 {print $1 " " $2}')
    capture_device_count=$(printf '%s\n' "$capture_devices" | awk 'NF {count++} END {print count+0}')
    [ "$capture_device_count" -eq 1 ] ||
      capture_die 'connect exactly one authorized ADB device or set ANDROID_SERIAL'
    capture_device_state=$(printf '%s\n' "$capture_devices" | awk 'NF {print $2}')
    [ "$capture_device_state" = device ] ||
      capture_die 'the single ADB device is not authorized and ready'
    capture_serial=$(printf '%s\n' "$capture_devices" | awk 'NF {print $1}')
  fi
  capture_state=$(ANDROID_SERIAL=$capture_serial "$capture_adb" get-state 2>/dev/null || printf 'unavailable')
  [ "$capture_state" = device ] || capture_die 'the selected ADB device is not authorized and ready'
}

capture_adb_call() {
  ANDROID_SERIAL=$capture_serial "$capture_adb" "$@"
}

capture_validate_android_user_id() {
  capture_user_id=$1
  case "$capture_user_id" in
    '' | *[!0-9]*) capture_die 'current Android user ID is not a strict non-negative integer' ;;
  esac
  case "$capture_user_id" in
    0 | [1-9]*) ;;
    *) capture_die 'current Android user ID is not canonical' ;;
  esac
  [ "${#capture_user_id}" -le 10 ] || capture_die 'current Android user ID is out of range'
  [ "$capture_user_id" -le 2147483647 ] || capture_die 'current Android user ID is out of range'
}

capture_detect_android_user() {
  if ! capture_android_user_raw=$(capture_adb_call shell -n am get-current-user 2>/dev/null); then
    capture_die 'current Android user could not be read'
  fi
  capture_cr=$(printf '\r')
  case "$capture_android_user_raw" in
    *"$capture_cr") capture_android_user_raw=${capture_android_user_raw%"$capture_cr"} ;;
  esac
  capture_validate_android_user_id "$capture_android_user_raw"
  capture_android_user_id=$capture_android_user_raw
}

capture_require_matching_android_user() {
  [ -n "$capture_expected_android_user_id" ] || capture_die 'session Android user binding is missing'
  capture_detect_android_user
  [ "$capture_android_user_id" = "$capture_expected_android_user_id" ] ||
    capture_die 'the current Android user does not match this session'
}

capture_run_as_call() {
  capture_run_as_package=$1
  shift
  capture_require_matching_android_user
  capture_adb_call shell -n -T run-as "$capture_run_as_package" \
    --user "$capture_expected_android_user_id" "$@"
}

capture_run_as_upload() {
  capture_run_as_package=$1
  shift
  # This preflight must never consume the caller's redirected artifact bytes.
  capture_require_matching_android_user
  capture_adb_call shell -T run-as "$capture_run_as_package" \
    --user "$capture_expected_android_user_id" "$@"
}

capture_read_value() {
  if [ "${1:-}" = shell ]; then
    shift
    capture_value=$(capture_adb_call shell -n "$@" 2>/dev/null || printf 'unavailable')
  else
    capture_value=$(capture_adb_call "$@" 2>/dev/null || printf 'unavailable')
  fi
  capture_value=$(printf '%s' "$capture_value" | tr -d '\r' | sed -n '1p' | cut -c 1-80)
  [ -n "$capture_value" ] || capture_value=empty
  printf '%s\n' "$capture_value"
}

capture_pidof() {
  capture_adb_call shell -n pidof "$1" 2>/dev/null | tr -d '\r' | sed -n '1p' || :
}

capture_require_debug_app_stopped_for_start() {
  # Do not use capture_pidof here: its best-effort contract hides ADB errors.
  # Shell-v2 preserves pidof's exit status; only exit 1 with no output means
  # absent. Retain stderr in the private variable so a transport error cannot
  # be mistaken for absence, but never include it or process IDs in an error.
  if capture_start_app_process=$(capture_adb_call shell -n -T pidof "$capture_package" 2>&1); then
    capture_start_app_process=$(printf '%s' "$capture_start_app_process" | tr -d '\r')
    case "$capture_start_app_process" in
      '' | *[!0-9\ ]*) capture_die 'could not verify that the debug app is stopped; start was not attempted' ;;
      *) capture_die 'debug app is running; quit it, run host start before Flutter, then reuse that session for app restarts' ;;
    esac
  else
    capture_start_app_process_status=$?
    [ "$capture_start_app_process_status" -eq 1 ] &&
      [ -z "$capture_start_app_process" ] ||
      capture_die 'could not verify that the debug app is stopped; start was not attempted'
  fi
}

capture_hci_status() {
  capture_hci_file=$1
  capture_secure=$(capture_read_value shell settings get secure bluetooth_hci_log)
  capture_global=$(capture_read_value shell settings get global bluetooth_btsnooplogmode)
  capture_persist=$(capture_read_value shell getprop persist.bluetooth.btsnooplogmode)
  capture_default=$(capture_read_value shell getprop persist.bluetooth.btsnoopdefaultmode)
  capture_hci_result=unverified
  capture_hci_explicit_full=false
  capture_hci_filtered=false
  capture_hci_legacy_enabled=false
  capture_hci_explicit_disabled=false
  for capture_value in "$capture_secure" "$capture_global" "$capture_persist" "$capture_default"; do
    case "$capture_value" in
      full) capture_hci_explicit_full=true ;;
      filtered) capture_hci_filtered=true ;;
      1 | true) capture_hci_legacy_enabled=true ;;
      0 | false | disabled) capture_hci_explicit_disabled=true ;;
    esac
  done
  if [ "$capture_hci_explicit_full" = true ]; then
    capture_hci_result=full
  elif [ "$capture_hci_filtered" = true ]; then
    capture_hci_result=filtered
  elif [ "$capture_hci_legacy_enabled" = true ] && [ "$capture_hci_explicit_disabled" = false ]; then
    capture_hci_result=full
  fi
  {
    printf 'verification=%s\n' "$capture_hci_result"
    printf 'secure.bluetooth_hci_log=%s\n' "$capture_secure"
    printf 'global.bluetooth_btsnooplogmode=%s\n' "$capture_global"
    printf 'persist.bluetooth.btsnooplogmode=%s\n' "$capture_persist"
    printf 'persist.bluetooth.btsnoopdefaultmode=%s\n' "$capture_default"
    printf '%s\n' 'note=read-only setting check; packet capture is not proven by this result'
  } >"$capture_hci_file"
  chmod 600 "$capture_hci_file"
  printf '%s\n' "$capture_hci_result"
}

capture_process_fingerprint() {
  capture_pid=$1
  capture_command=$(ps -p "$capture_pid" -o command= 2>/dev/null || :)
  capture_started=$(ps -p "$capture_pid" -o lstart= 2>/dev/null || :)
  [ -n "$capture_command" ] || return 1
  [ -n "$capture_started" ] || return 1
  case "$capture_command" in
    *adb*logcat*'-b all'*) ;;
    *) return 1 ;;
  esac
  capture_sha256_text "$capture_started|$capture_command"
}

capture_stop_pid_safely() {
  capture_pid=$1
  capture_expected=$2
  kill -0 "$capture_pid" 2>/dev/null || return 0
  capture_actual=$(capture_process_fingerprint "$capture_pid" || :)
  [ -n "$capture_actual" ] || capture_die 'refusing to stop an unrecognized process'
  [ "$capture_actual" = "$capture_expected" ] ||
    capture_die 'refusing to stop a process whose identity changed'
  kill -TERM "$capture_pid"
  capture_wait=0
  while kill -0 "$capture_pid" 2>/dev/null && [ "$capture_wait" -lt 50 ]; do
    sleep 0.1
    capture_wait=$((capture_wait + 1))
  done
  if kill -0 "$capture_pid" 2>/dev/null; then
    capture_die 'logcat did not stop after SIGTERM'
  fi
  return 0
}

capture_cleanup_start() {
  if [ "${capture_package:-}" = com.openglucose.app.debug ] &&
    capture_has_exact_arm_rf_lease; then
    capture_remove_target_unverified_grants >/dev/null 2>&1 || :
  fi
  capture_release_arm_rf_lease >/dev/null 2>&1 || :
  [ -n "$capture_cleanup_pid" ] || return 0
  if [ -n "$capture_cleanup_fingerprint" ]; then
    capture_stop_pid_safely "$capture_cleanup_pid" "$capture_cleanup_fingerprint" || :
  elif kill -0 "$capture_cleanup_pid" 2>/dev/null; then
    # This PID was created by the current start command and has not yet been
    # handed to another process, so it is safe to stop during start rollback.
    kill -TERM "$capture_cleanup_pid" 2>/dev/null || :
  fi
  if [ -n "$capture_cleanup_session" ] && [ -d "$capture_cleanup_session" ]; then
    printf '%s\n' failed >"$capture_cleanup_session/state"
  fi
}

capture_remove_target_unverified_grants() {
  capture_patch_grant_path=files/protocol-captures/target-unverified-nfc-grant.json
  capture_patch_grant_pending=$capture_patch_grant_path.pending
  capture_fram_grant_path=files/protocol-captures/target-unverified-gen1-fram-read-grant.json
  capture_fram_grant_pending=$capture_fram_grant_path.pending
  capture_activation_grant_path=files/protocol-captures/target-unverified-gen1-activation-grant.json
  capture_activation_grant_pending=$capture_activation_grant_path.pending
  capture_remove_result=0
  capture_run_as_call com.openglucose.app.debug rm -f "$capture_patch_grant_path" || capture_remove_result=1
  capture_run_as_call com.openglucose.app.debug rm -f "$capture_patch_grant_pending" || capture_remove_result=1
  capture_run_as_call com.openglucose.app.debug rm -f "$capture_fram_grant_path" || capture_remove_result=1
  capture_run_as_call com.openglucose.app.debug rm -f "$capture_fram_grant_pending" || capture_remove_result=1
  capture_run_as_call com.openglucose.app.debug rm -f "$capture_activation_grant_path" || capture_remove_result=1
  capture_run_as_call com.openglucose.app.debug rm -f "$capture_activation_grant_pending" || capture_remove_result=1
  capture_run_as_call com.openglucose.app.debug sync files/protocol-captures || capture_remove_result=1
  return "$capture_remove_result"
}

capture_acquire_arm_rf_lease() {
  capture_lease_seed="${capture_session##*/}|$capture_expected_device|$capture_expected_android_user_id|$$|$(capture_host_monotonic_nanos)"
  capture_lease_token=host_$(capture_sha256_text "$capture_lease_seed")
  capture_arm_lease_owner_file=$capture_arm_lease_directory/owner-$capture_lease_token
  if ! capture_run_as_call "$capture_package" mkdir "$capture_arm_lease_directory"; then
    capture_die 'another NFC setup, arm, or RF transaction owns the app-private lease'
  fi
  if ! capture_run_as_call "$capture_package" touch "$capture_arm_lease_owner_file"; then
    capture_run_as_call "$capture_package" rmdir "$capture_arm_lease_directory" >/dev/null 2>&1 || :
    capture_die 'could not create the app-private NFC RF lease owner'
  fi
  capture_arm_lease_owned=true
  capture_run_as_call "$capture_package" chmod 700 "$capture_arm_lease_directory" ||
    capture_die 'could not protect the app-private NFC RF lease directory'
  capture_run_as_call "$capture_package" chmod 600 "$capture_arm_lease_owner_file" ||
    capture_die 'could not protect the app-private NFC RF lease owner'
  capture_run_as_call "$capture_package" sync "$capture_arm_lease_owner_file" ||
    capture_die 'could not durably flush the app-private NFC RF lease owner'
  capture_run_as_call "$capture_package" sync "$capture_arm_lease_directory" ||
    capture_die 'could not durably flush the app-private NFC RF lease directory'
}

capture_release_arm_rf_lease() {
  [ "$capture_arm_lease_owned" = true ] || return 0
  [ -n "$capture_arm_lease_owner_file" ] || return 1
  capture_release_result=0
  if ! capture_has_exact_arm_rf_lease; then
    return 1
  fi
  capture_run_as_call "$capture_package" rm -f "$capture_arm_lease_owner_file" ||
    capture_release_result=1
  if [ "$capture_release_result" -eq 0 ]; then
    capture_run_as_call "$capture_package" rmdir "$capture_arm_lease_directory" ||
      capture_release_result=1
  fi
  capture_run_as_call "$capture_package" sync files/protocol-captures ||
    capture_release_result=1
  if [ "$capture_release_result" -eq 0 ]; then
    capture_arm_lease_owned=false
    capture_arm_lease_owner_file=
  fi
  return "$capture_release_result"
}

capture_has_exact_arm_rf_lease() {
  [ "$capture_arm_lease_owned" = true ] || return 1
  [ -n "$capture_arm_lease_owner_file" ] || return 1
  capture_expected_lease_entry=${capture_arm_lease_owner_file##*/}
  if ! capture_actual_lease_entries=$(
    capture_run_as_call "$capture_package" ls -1A "$capture_arm_lease_directory" 2>/dev/null
  ); then
    return 1
  fi
  [ "$capture_actual_lease_entries" = "$capture_expected_lease_entry" ]
}

capture_cleanup_arm() {
  if [ "$capture_arm_cleanup_device" = true ] && capture_has_exact_arm_rf_lease; then
    capture_remove_target_unverified_grants >/dev/null 2>&1 || :
  fi
  capture_release_arm_rf_lease >/dev/null 2>&1 || :
  if [ -n "$capture_grant_temp_dir" ] && [ -d "$capture_grant_temp_dir" ]; then
    rm -f "$capture_grant_temp_dir/context.json" "$capture_grant_temp_dir/target.json" \
      "$capture_grant_temp_dir/patch.json" "$capture_grant_temp_dir/grant.json" \
      "$capture_grant_temp_dir/source-validation.json" \
      "$capture_grant_temp_dir/source-validation.stderr" \
      "$capture_grant_temp_dir/grant-validation.stderr"
    rmdir "$capture_grant_temp_dir" 2>/dev/null || :
  fi
}

capture_cleanup_collect() {
  if [ "$capture_arm_lease_owned" = true ]; then
    if capture_has_exact_arm_rf_lease; then
      capture_collect_remote_cleanup_ok=true
      if [ "$capture_rebind_promotion_started" = true ] &&
        [ "$capture_rebind_committed" != true ]; then
        if [ -n "$capture_rebind_backup_path" ] &&
          capture_run_as_call "$capture_package" mv \
            "$capture_rebind_backup_path" "$capture_source" >/dev/null 2>&1 &&
          capture_run_as_call "$capture_package" sync \
            files/protocol-captures >/dev/null 2>&1 &&
          capture_run_as_call "$capture_package" cat "$capture_source" \
            >"$capture_collect_temp_dir/rebind-rollback-readback.json" 2>/dev/null &&
          cmp -s "$capture_collect_temp_dir/rebind-original.json" \
            "$capture_collect_temp_dir/rebind-rollback-readback.json"; then
          capture_rebind_promotion_started=false
          capture_rebind_promoted=false
        else
          capture_collect_remote_cleanup_ok=false
          printf '%s\n' \
            'error: app-private FRAM rebind rollback could not be proven; the exact NFC RF lease remains quarantined' >&2
        fi
      fi
      if [ "$capture_collect_remote_cleanup_ok" = true ] &&
        [ "$capture_rebind_workspace_owned" = true ]; then
        capture_run_as_call "$capture_package" rm -f \
          "$capture_rebind_pending_path" "$capture_rebind_backup_path" \
          "$capture_rebind_workspace_marker" >/dev/null 2>&1 ||
          capture_collect_remote_cleanup_ok=false
        capture_run_as_call "$capture_package" rmdir \
          "$capture_rebind_workspace" >/dev/null 2>&1 ||
          capture_collect_remote_cleanup_ok=false
        capture_run_as_call "$capture_package" sync \
          files/protocol-captures >/dev/null 2>&1 ||
          capture_collect_remote_cleanup_ok=false
        if [ "$capture_collect_remote_cleanup_ok" = true ]; then
          capture_rebind_workspace_owned=false
        fi
      fi
      if [ "$capture_collect_remote_cleanup_ok" = true ]; then
        capture_release_arm_rf_lease >/dev/null 2>&1 || :
      fi
    fi
  fi
  if [ "$capture_collect_cleanup_destination" = true ]; then
    rm -f "$capture_collect_destination" "$capture_collect_destination.pending" \
      "$capture_collect_hash_destination" "$capture_collect_hash_destination.pending"
  fi
  if [ -n "$capture_collect_temp_dir" ] && [ -d "$capture_collect_temp_dir" ]; then
    rm -f "$capture_collect_temp_dir/artifact.json" \
      "$capture_collect_temp_dir/artifact.stderr" \
      "$capture_collect_temp_dir/target.json" \
      "$capture_collect_temp_dir/patch.json" \
      "$capture_collect_temp_dir/rebind-original.json" \
      "$capture_collect_temp_dir/rebind-backup-readback.json" \
      "$capture_collect_temp_dir/rebind-pending-readback.json" \
      "$capture_collect_temp_dir/rebind-rollback-readback.json" \
      "$capture_collect_temp_dir/rebound.json" \
      "$capture_collect_temp_dir/rebound-readback.json" \
      "$capture_collect_temp_dir/validation.stderr"
    rmdir "$capture_collect_temp_dir" 2>/dev/null || :
  fi
}

capture_build_target_unverified_grant() {
  capture_context_file=$1
  capture_target_file=$2
  capture_selection_file=$3
  capture_grant_file=$4
  capture_grant_session_id=$5
  capture_grant_issued_at=$6
  ruby -rjson -e '
    context = JSON.parse(File.read(ARGV.fetch(0)))
    target = JSON.parse(File.read(ARGV.fetch(1)))
    selected = File.readlines(ARGV.fetch(2), chomp: true).to_h { |line| line.split("=", 2) }
    session_id = ARGV.fetch(4)
    context_keys = %w[schemaVersion nonce nativeCaptureSessionId processSessionId versionCode lastUpdateTime expectedReferenceIso15693ManufacturerPrefix].sort
    target_keys = %w[schemaVersion nativeCaptureSessionId processSessionId targetUidSha256 iso15693ManufacturerPrefix observedAtUtc observedAtMonotonicElapsedNanos].sort
    valid = context.is_a?(Hash) &&
      context.keys.sort == context_keys && target.is_a?(Hash) && target.keys.sort == target_keys &&
      context["schemaVersion"] == 1 &&
      context["nonce"].is_a?(String) &&
      context["nonce"].match?(/\A[A-Za-z0-9_-]{16,128}\z/) &&
      context["nativeCaptureSessionId"] == selected["native_session"] &&
      context["processSessionId"] == selected["process_session"] &&
      context["versionCode"].is_a?(Integer) && context["versionCode"] > 0 &&
      context["lastUpdateTime"].is_a?(Integer) && context["lastUpdateTime"] > 0 &&
      context["versionCode"].to_s == selected["version_code"] &&
      context["lastUpdateTime"].to_s == selected["last_update_time"] &&
      context["expectedReferenceIso15693ManufacturerPrefix"] == "e007" &&
      target["schemaVersion"] == 1 &&
      target["nativeCaptureSessionId"] == selected["native_session"] &&
      target["processSessionId"] == selected["process_session"] &&
      target["targetUidSha256"].is_a?(String) && target["targetUidSha256"].match?(/\A[0-9a-f]{64}\z/) &&
      target["iso15693ManufacturerPrefix"] == "e007" &&
      session_id.match?(/\Asession-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\z/) &&
      ARGV.fetch(5).match?(/\A[0-9]{13}\z/)
    abort "invalid or non-current NFC grant/target context" unless valid
    issued_at = ARGV.fetch(5).to_i
    grant = {
      "schemaVersion" => 1,
      "nonce" => context.fetch("nonce"),
      "nativeCaptureSessionId" => context.fetch("nativeCaptureSessionId"),
      "processSessionId" => context.fetch("processSessionId"),
      "versionCode" => context.fetch("versionCode"),
      "lastUpdateTime" => context.fetch("lastUpdateTime"),
      "targetUidSha256" => target.fetch("targetUidSha256"),
      "iso15693ManufacturerPrefix" => "e007",
      "operation" => "target_unverified_patch_info_probe",
      "sessionId" => session_id,
      "issuedAtEpochMillis" => issued_at,
      "expiresAtEpochMillis" => issued_at + 90_000
    }
    File.open(ARGV.fetch(3), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(grant))
      file.write("\n")
      file.flush
      file.fsync
    end
  ' "$capture_context_file" "$capture_target_file" "$capture_selection_file" "$capture_grant_file" \
    "$capture_grant_session_id" "$capture_grant_issued_at"
}

capture_build_reused_target_unverified_grant() {
  capture_context_file=$1
  capture_source_session=$2
  capture_selection_file=$3
  capture_grant_file=$4
  capture_grant_session_id=$5
  capture_grant_issued_at=$6
  capture_expected_device_hash=$7
  capture_expected_user_id=$8
  ruby -rjson -rtime -rdigest -e '
    def read_private(path, maximum)
      before = File.lstat(path)
      abort "unsafe reusable target evidence" unless before.file? && !before.symlink? && (before.mode & 0o777) == 0o600
      flags = File::RDONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(path, flags) do |file|
        current = file.stat
        abort "changed reusable target evidence" unless current.file? && current.dev == before.dev && current.ino == before.ino && (current.mode & 0o777) == 0o600
        value = file.read(maximum + 1)
        abort "oversized reusable target evidence" if value.bytesize > maximum
        value
      end
    end
    def properties(text)
      result = {}
      text.lines(chomp: true).each do |line|
        key, value = line.split("=", 2)
        abort "invalid reusable target properties" if key.nil? || value.nil? || result.key?(key)
        result[key] = value
      end
      result
    end
    class UniqueObject < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate key" if key?(key)
        super
      end
    end
    source = ARGV.fetch(1)
    source_id = File.basename(source)
    source_stat = File.lstat(source)
    abort "unsafe reusable target session" unless source_stat.directory? && !source_stat.symlink? && (source_stat.mode & 0o777) == 0o700
    sentinel = read_private(File.join(source, ".openglucose-passive-capture"), 128)
    abort "invalid reusable target marker" unless sentinel == "schema=1\n"
    session = properties(read_private(File.join(source, "session.properties"), 4096))
    legacy_keys = %w[schema session_id created_utc package device_serial_sha256 android_user_id capture_profile mode].sort
    current_keys = (legacy_keys + ["capture_live_aidex"]).sort
    abort "invalid reusable target session schema" unless [legacy_keys, current_keys].include?(session.keys.sort)
    live = session.fetch("capture_live_aidex", "false")
    expected_mode = live == "true" ? "full-ui-live-aidex-plus-protocol-capture" : "passive-until-separately-armed"
    valid_session = session["schema"] == "1" && session["session_id"] == source_id &&
      source_id.match?(/\Asession-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\z/) &&
      !((Time.iso8601(session["created_utc"]) rescue nil).nil?) &&
      session["package"] == "com.openglucose.app.debug" &&
      session["device_serial_sha256"] == ARGV.fetch(6) &&
      session["android_user_id"] == ARGV.fetch(7) && session["capture_profile"] == "libre" &&
      %w[true false].include?(live) && session["mode"] == expected_mode
    abort "reusable target session is not compatible" unless valid_session
    target_text = read_private(File.join(source, "target-observation.json"), 4096)
    target_hash_text = read_private(File.join(source, "target-observation.sha256"), 128)
    abort "invalid reusable target hash marker" unless target_hash_text.match?(/\A[0-9a-f]{64}\n\z/) &&
      Digest::SHA256.hexdigest(target_text) == target_hash_text.strip
    target = JSON.parse(target_text, object_class: UniqueObject)
    target_keys = %w[schemaVersion nativeCaptureSessionId processSessionId targetUidSha256 iso15693ManufacturerPrefix observedAtUtc observedAtMonotonicElapsedNanos].sort
    target_valid = target.is_a?(Hash) && target.keys.sort == target_keys && target["schemaVersion"] == 1 &&
      target["nativeCaptureSessionId"].is_a?(String) && target["nativeCaptureSessionId"].match?(/\A[A-Za-z0-9_-]{8,160}\z/) &&
      target["processSessionId"].is_a?(String) && target["processSessionId"].match?(/\A[A-Za-z0-9_-]{8,160}\z/) &&
      target["targetUidSha256"].is_a?(String) && target["targetUidSha256"].match?(/\A[0-9a-f]{64}\z/) &&
      target["iso15693ManufacturerPrefix"] == "e007" &&
      target["observedAtMonotonicElapsedNanos"].is_a?(Integer) && target["observedAtMonotonicElapsedNanos"] > 0 &&
      !((Time.iso8601(target["observedAtUtc"]) rescue nil).nil?)
    abort "invalid reusable target observation" unless target_valid
    readiness_match = Dir.glob(File.join(source, "readiness", "[0-9][0-9][0-9][0-9]", "selection.properties")).any? do |selection_path|
      directory = File.dirname(selection_path)
      directory_stat = File.lstat(directory)
      next false unless directory_stat.directory? && !directory_stat.symlink? && (directory_stat.mode & 0o777) == 0o700
      selection_text = read_private(selection_path, 4096)
      hashes_text = read_private(File.join(directory, "hashes.sha256"), 65_536)
      expected = Digest::SHA256.hexdigest(selection_text)
      next false unless hashes_text.lines(chomp: true).count { |line| line == "#{expected}  selection.properties" } == 1
      selected_source = properties(selection_text)
      selected_source["native_session"] == target["nativeCaptureSessionId"] &&
        selected_source["process_session"] == target["processSessionId"]
    rescue Errno::ENOENT, Errno::ELOOP
      false
    end
    abort "reusable target has no hashed host-readiness marker" unless readiness_match
    context = JSON.parse(File.read(ARGV.fetch(0)), object_class: UniqueObject)
    selected = properties(File.read(ARGV.fetch(2)))
    context_keys = %w[schemaVersion nonce nativeCaptureSessionId processSessionId versionCode lastUpdateTime expectedReferenceIso15693ManufacturerPrefix].sort
    valid_context = context.is_a?(Hash) && context.keys.sort == context_keys && context["schemaVersion"] == 1 &&
      context["nonce"].is_a?(String) && context["nonce"].match?(/\A[A-Za-z0-9_-]{16,128}\z/) &&
      context["nativeCaptureSessionId"] == selected["native_session"] && context["processSessionId"] == selected["process_session"] &&
      context["versionCode"].is_a?(Integer) && context["versionCode"].to_s == selected["version_code"] &&
      context["lastUpdateTime"].is_a?(Integer) && context["lastUpdateTime"].to_s == selected["last_update_time"] &&
      context["expectedReferenceIso15693ManufacturerPrefix"] == "e007" &&
      ARGV.fetch(4).match?(/\Asession-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\z/) && ARGV.fetch(5).match?(/\A[0-9]{13}\z/)
    abort "invalid current NFC grant context" unless valid_context
    issued_at = ARGV.fetch(5).to_i
    grant = {"schemaVersion"=>1,"nonce"=>context.fetch("nonce"),"nativeCaptureSessionId"=>context.fetch("nativeCaptureSessionId"),
      "processSessionId"=>context.fetch("processSessionId"),"versionCode"=>context.fetch("versionCode"),"lastUpdateTime"=>context.fetch("lastUpdateTime"),
      "targetUidSha256"=>target.fetch("targetUidSha256"),"iso15693ManufacturerPrefix"=>target.fetch("iso15693ManufacturerPrefix"),
      "operation"=>"target_unverified_patch_info_probe","sessionId"=>ARGV.fetch(4),"issuedAtEpochMillis"=>issued_at,"expiresAtEpochMillis"=>issued_at+90_000}
    File.open(ARGV.fetch(3), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(grant)+"\n"); file.flush; file.fsync }
  ' "$capture_context_file" "$capture_source_session" "$capture_selection_file" "$capture_grant_file" \
    "$capture_grant_session_id" "$capture_grant_issued_at" "$capture_expected_device_hash" "$capture_expected_user_id"
}

capture_build_target_unverified_gen1_fram_grant() {
  capture_context_file=$1
  capture_target_file=$2
  capture_patch_file=$3
  capture_selection_file=$4
  capture_grant_file=$5
  capture_grant_session_id=$6
  capture_grant_issued_at=$7
  ruby -rjson -rtime -e '
    context = JSON.parse(File.read(ARGV.fetch(0)))
    target = JSON.parse(File.read(ARGV.fetch(1)))
    patch = JSON.parse(File.read(ARGV.fetch(2)))
    selected = File.readlines(ARGV.fetch(3), chomp: true).to_h { |line| line.split("=", 2) }
    session_id = ARGV.fetch(5)
    issued_text = ARGV.fetch(6)
    context_keys = %w[schemaVersion nonce nativeCaptureSessionId processSessionId versionCode lastUpdateTime expectedReferenceIso15693ManufacturerPrefix].sort
    target_keys = %w[schemaVersion nativeCaptureSessionId processSessionId targetUidSha256 iso15693ManufacturerPrefix observedAtUtc observedAtMonotonicElapsedNanos].sort
    patch_keys = %w[schemaVersion nativeCaptureSessionId processSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix model generation patchInfoSha256 observedAtUtc observedAtMonotonicElapsedNanos].sort
    parse_utc_ms = lambda do |value|
      next nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\z/)
      (Time.iso8601(value).to_r * 1000).to_i rescue nil
    end
    issued_at = issued_text.match?(/\A[0-9]{13}\z/) ? issued_text.to_i : nil
    target_utc_ms = target.is_a?(Hash) ? parse_utc_ms.call(target["observedAtUtc"]) : nil
    patch_utc_ms = patch.is_a?(Hash) ? parse_utc_ms.call(patch["observedAtUtc"]) : nil
    age_valid = lambda do |timestamp_ms|
      !issued_at.nil? && !timestamp_ms.nil? && issued_at - timestamp_ms >= -5_000 &&
        issued_at - timestamp_ms <= 120_000
    end
    valid = context.is_a?(Hash) && context.keys.sort == context_keys &&
      target.is_a?(Hash) && target.keys.sort == target_keys &&
      patch.is_a?(Hash) && patch.keys.sort == patch_keys &&
      context["schemaVersion"] == 1 &&
      context["nonce"].is_a?(String) &&
      context["nonce"].match?(/\A[A-Za-z0-9_-]{16,128}\z/) &&
      context["nativeCaptureSessionId"] == selected["native_session"] &&
      context["processSessionId"] == selected["process_session"] &&
      context["versionCode"].is_a?(Integer) && context["versionCode"] > 0 &&
      context["lastUpdateTime"].is_a?(Integer) && context["lastUpdateTime"] > 0 &&
      context["versionCode"].to_s == selected["version_code"] &&
      context["lastUpdateTime"].to_s == selected["last_update_time"] &&
      context["expectedReferenceIso15693ManufacturerPrefix"] == "e007" &&
      target["schemaVersion"] == 1 &&
      target["nativeCaptureSessionId"] == selected["native_session"] &&
      target["processSessionId"] == selected["process_session"] &&
      target["targetUidSha256"].is_a?(String) && target["targetUidSha256"].match?(/\A[0-9a-f]{64}\z/) &&
      target["iso15693ManufacturerPrefix"] == "e007" &&
      target["observedAtMonotonicElapsedNanos"].is_a?(Integer) &&
      target["observedAtMonotonicElapsedNanos"] > 0 && age_valid.call(target_utc_ms) &&
      patch["schemaVersion"] == 1 &&
      patch["nativeCaptureSessionId"] == selected["native_session"] &&
      patch["processSessionId"] == selected["process_session"] &&
      patch["versionCode"].is_a?(Integer) && patch["versionCode"].to_s == selected["version_code"] &&
      patch["lastUpdateTime"].is_a?(Integer) && patch["lastUpdateTime"].to_s == selected["last_update_time"] &&
      patch["targetUidSha256"] == target["targetUidSha256"] &&
      patch["iso15693ManufacturerPrefix"] == target["iso15693ManufacturerPrefix"] &&
      %w[libre2 libre2Plus].include?(patch["model"]) && patch["generation"] == "gen1" &&
      patch["patchInfoSha256"].is_a?(String) && patch["patchInfoSha256"].match?(/\A[0-9a-f]{64}\z/) &&
      patch["observedAtMonotonicElapsedNanos"].is_a?(Integer) &&
      patch["observedAtMonotonicElapsedNanos"] >= target["observedAtMonotonicElapsedNanos"] &&
      age_valid.call(patch_utc_ms) && patch_utc_ms >= target_utc_ms &&
      session_id.match?(/\Asession-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\z/)
    abort "invalid, stale, or cross-bound Gen1 FRAM grant context" unless valid
    grant = {
      "schemaVersion" => 1,
      "nonce" => context.fetch("nonce"),
      "nativeCaptureSessionId" => context.fetch("nativeCaptureSessionId"),
      "processSessionId" => context.fetch("processSessionId"),
      "versionCode" => context.fetch("versionCode"),
      "lastUpdateTime" => context.fetch("lastUpdateTime"),
      "targetUidSha256" => target.fetch("targetUidSha256"),
      "iso15693ManufacturerPrefix" => "e007",
      "patchInfoSha256" => patch.fetch("patchInfoSha256"),
      "operation" => "target_unverified_gen1_fram_read",
      "sessionId" => session_id,
      "issuedAtEpochMillis" => issued_at,
      "expiresAtEpochMillis" => issued_at + 300_000
    }
    File.open(ARGV.fetch(4), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(grant))
      file.write("\n")
      file.flush
      file.fsync
    end
  ' "$capture_context_file" "$capture_target_file" "$capture_patch_file" \
    "$capture_selection_file" "$capture_grant_file" "$capture_grant_session_id" \
    "$capture_grant_issued_at"
}

capture_build_target_unverified_gen1_activation_grant() {
  capture_context_file=$1
  capture_target_file=$2
  capture_patch_file=$3
  capture_source_file=$4
  capture_source_hash=$5
  capture_validation_file=$6
  capture_selection_file=$7
  capture_grant_file=$8
  capture_grant_session_id=$9
  shift 9
  capture_grant_issued_at=$1
  ruby -rjson -rtime -rdigest -rsecurerandom -e '
    context = JSON.parse(File.read(ARGV.fetch(0)))
    target = JSON.parse(File.read(ARGV.fetch(1)))
    patch = JSON.parse(File.read(ARGV.fetch(2)))
    source_path = ARGV.fetch(3)
    source = JSON.parse(File.read(source_path))
    source_expected_hash = ARGV.fetch(4)
    validation = JSON.parse(File.read(ARGV.fetch(5)))
    selected = File.readlines(ARGV.fetch(6), chomp: true).to_h { |line| line.split("=", 2) }
    session_id = ARGV.fetch(8)
    issued_text = ARGV.fetch(9)
    context_keys = %w[schemaVersion nonce nativeCaptureSessionId processSessionId versionCode lastUpdateTime expectedReferenceIso15693ManufacturerPrefix].sort
    target_keys = %w[schemaVersion nativeCaptureSessionId processSessionId targetUidSha256 iso15693ManufacturerPrefix observedAtUtc observedAtMonotonicElapsedNanos].sort
    patch_keys = %w[schemaVersion nativeCaptureSessionId processSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix model generation patchInfoSha256 observedAtUtc observedAtMonotonicElapsedNanos].sort
    host_source_keys = %w[schemaVersion nativeCaptureSessionId processSessionId captureSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix patchInfoSha256 model securityGeneration algorithmOrderUidHex patchInfoHex encryptedFramHex observedAtUtc observedAtMonotonicElapsedNanos].sort
    explicit_source_keys = (host_source_keys + %w[sourceKind explicitAttemptId]).sort
    validation_keys = %w[validated model lifecycle length evidenceStatus].sort
    issued_at = issued_text.match?(/\A[0-9]{13}\z/) ? issued_text.to_i : nil
    parse_utc_ms = lambda do |value|
      next nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\z/)
      (Time.iso8601(value).to_r * 1000).to_i rescue nil
    end
    target_ms = target.is_a?(Hash) ? parse_utc_ms.call(target["observedAtUtc"]) : nil
    patch_ms = patch.is_a?(Hash) ? parse_utc_ms.call(patch["observedAtUtc"]) : nil
    fresh = lambda do |timestamp_ms|
      !issued_at.nil? && !timestamp_ms.nil? && issued_at - timestamp_ms >= -5_000 && issued_at - timestamp_ms <= 120_000
    end
    uid = source.is_a?(Hash) && source["algorithmOrderUidHex"].is_a?(String) && source["algorithmOrderUidHex"].match?(/\A[0-9a-f]{16}\z/) ? [source["algorithmOrderUidHex"]].pack("H*") : nil
    patch_bytes = source.is_a?(Hash) && source["patchInfoHex"].is_a?(String) && source["patchInfoHex"].match?(/\A[0-9a-f]{12}\z/) ? [source["patchInfoHex"]].pack("H*") : nil
    encrypted = source.is_a?(Hash) && source["encryptedFramHex"].is_a?(String) && source["encryptedFramHex"].match?(/\A[0-9a-f]{688}\z/) ? [source["encryptedFramHex"]].pack("H*") : nil
    source_actual_hash = Digest::SHA256.file(source_path).hexdigest
    target_hash = uid.nil? ? nil : Digest::SHA256.hexdigest(uid)
    patch_hash = patch_bytes.nil? ? nil : Digest::SHA256.hexdigest(patch_bytes)
    manufacturer = uid.nil? ? nil : uid.bytes.values_at(7, 6).pack("C*").unpack1("H*")

    planned = nil
    unless uid.nil?
      key = [0xa0c5, 0x6860, 0x0000, 0x14c6]
      le16 = ->(bytes, offset) { bytes.getbyte(offset) | (bytes.getbyte(offset + 1) << 8) }
      operation = lambda do |value|
        result = value >> 2
        result ^= key[1] unless (value & 1).zero?
        result ^= key[0] unless (value & 2).zero?
        result & 0xffff
      end
      input = [
        (le16.call(uid, 4) + 0x1b + 0x1b6a) & 0xffff,
        (le16.call(uid, 2) + key[2]) & 0xffff,
        (le16.call(uid, 0) + 0x1b * 2) & 0xffff,
        0x241a ^ key[3]
      ]
      r0 = operation.call(input[0]) ^ input[3]
      r1 = operation.call(r0) ^ input[2]
      r2 = operation.call(r1) ^ input[1]
      r3 = operation.call(r2) ^ input[0]
      r4 = operation.call(r3)
      r5 = operation.call(r4 ^ r0)
      r6 = operation.call(r5 ^ r1)
      r7 = operation.call(r6 ^ r2)
      words = [(r3 ^ r7) & 0xffff, (r2 ^ r6) & 0xffff]
      auth = [words[0] ^ 0x4163, words[1] ^ 0x4344].pack("v*")
      planned = [0x02, 0xa1, uid.getbyte(6), 0x1b].pack("C*") + auth
    end
    source_schema_valid = source.is_a?(Hash) &&
      ((source["schemaVersion"] == 1 && source.keys.sort == host_source_keys) ||
        (source["schemaVersion"] == 2 && source.keys.sort == explicit_source_keys &&
          source["sourceKind"] == "explicitLibre2Lifecycle" &&
          source["explicitAttemptId"].is_a?(String) &&
          source["explicitAttemptId"].match?(/\A[A-Za-z0-9_-]{8,120}\z/)))
    valid = context.is_a?(Hash) && context.keys.sort == context_keys &&
      target.is_a?(Hash) && target.keys.sort == target_keys &&
      patch.is_a?(Hash) && patch.keys.sort == patch_keys &&
      source_schema_valid &&
      validation.is_a?(Hash) && validation.keys.sort == validation_keys &&
      validation == {"validated"=>true,"model"=>"libre2","lifecycle"=>"notActivated","length"=>344,"evidenceStatus"=>"referenceVerifiedTargetUnverified"} &&
      context["schemaVersion"] == 1 && context["nonce"].is_a?(String) && context["nonce"].match?(/\A[A-Za-z0-9_-]{16,128}\z/) &&
      context["nativeCaptureSessionId"] == selected["native_session"] && context["processSessionId"] == selected["process_session"] &&
      context["versionCode"].is_a?(Integer) && context["versionCode"].to_s == selected["version_code"] &&
      context["lastUpdateTime"].is_a?(Integer) && context["lastUpdateTime"].to_s == selected["last_update_time"] &&
      context["expectedReferenceIso15693ManufacturerPrefix"] == "e007" &&
      target["schemaVersion"] == 1 && target["nativeCaptureSessionId"] == selected["native_session"] && target["processSessionId"] == selected["process_session"] &&
      target["targetUidSha256"].is_a?(String) && target["targetUidSha256"].match?(/\A[0-9a-f]{64}\z/) && target["iso15693ManufacturerPrefix"] == "e007" && target["observedAtMonotonicElapsedNanos"].is_a?(Integer) && target["observedAtMonotonicElapsedNanos"] > 0 && fresh.call(target_ms) &&
      patch["schemaVersion"] == 1 && patch["nativeCaptureSessionId"] == selected["native_session"] && patch["processSessionId"] == selected["process_session"] &&
      patch["versionCode"].to_s == selected["version_code"] && patch["lastUpdateTime"].to_s == selected["last_update_time"] &&
      patch["targetUidSha256"] == target["targetUidSha256"] && patch["iso15693ManufacturerPrefix"] == "e007" && patch["model"] == "libre2" && patch["generation"] == "gen1" &&
      patch["patchInfoSha256"].is_a?(String) && patch["patchInfoSha256"].match?(/\A[0-9a-f]{64}\z/) && patch["observedAtMonotonicElapsedNanos"].is_a?(Integer) && patch["observedAtMonotonicElapsedNanos"] >= target["observedAtMonotonicElapsedNanos"] && fresh.call(patch_ms) && patch_ms >= target_ms &&
      source["nativeCaptureSessionId"] == selected["native_session"] && source["processSessionId"] == selected["process_session"] &&
      source["captureSessionId"] == session_id && source["versionCode"].to_s == selected["version_code"] && source["lastUpdateTime"].to_s == selected["last_update_time"] &&
      source["targetUidSha256"] == target["targetUidSha256"] && source["targetUidSha256"] == target_hash &&
      source["iso15693ManufacturerPrefix"] == "e007" && manufacturer == "e007" &&
      source["patchInfoSha256"] == patch["patchInfoSha256"] && source["patchInfoSha256"] == patch_hash &&
      source["model"] == "libre2" && source["securityGeneration"] == "gen1" &&
      source["observedAtMonotonicElapsedNanos"].is_a?(Integer) && source["observedAtMonotonicElapsedNanos"] >= patch["observedAtMonotonicElapsedNanos"] && !parse_utc_ms.call(source["observedAtUtc"]).nil? &&
      source_expected_hash.match?(/\A[0-9a-f]{64}\z/) && source_actual_hash == source_expected_hash &&
      !encrypted.nil? && !planned.nil? && !issued_at.nil? &&
      session_id.match?(/\Asession-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\z/)
    abort "invalid or cross-bound Gen1 activation source" unless valid
    grant = {
      "schemaVersion" => 1,
      "nonce" => context.fetch("nonce"),
      "nativeCaptureSessionId" => context.fetch("nativeCaptureSessionId"),
      "processSessionId" => context.fetch("processSessionId"),
      "versionCode" => context.fetch("versionCode"),
      "lastUpdateTime" => context.fetch("lastUpdateTime"),
      "targetUidSha256" => target.fetch("targetUidSha256"),
      "iso15693ManufacturerPrefix" => "e007",
      "patchInfoSha256" => patch.fetch("patchInfoSha256"),
      "model" => "libre2",
      "securityGeneration" => "gen1",
      "operation" => "target_unverified_gen1_activation",
      "sessionId" => session_id,
      "attemptId" => "activation-#{SecureRandom.hex(16)}",
      "sourceFramCaptureSha256" => source_actual_hash,
      "sourceEncryptedFramSha256" => Digest::SHA256.hexdigest(encrypted),
      "validatedLifecycle" => "notActivated",
      "plannedRequestSha256" => Digest::SHA256.hexdigest(planned),
      "issuedAtEpochMillis" => issued_at,
      "expiresAtEpochMillis" => issued_at + 90_000
    }
    File.open(ARGV.fetch(7), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(grant)); file.write("\n"); file.flush; file.fsync
    end
  ' "$capture_context_file" "$capture_target_file" "$capture_patch_file" \
    "$capture_source_file" "$capture_source_hash" "$capture_validation_file" \
    "$capture_selection_file" "$capture_grant_file" "$capture_grant_session_id" \
    "$capture_grant_issued_at"
}

capture_require_session() {
  capture_session=$(capture_canonical_candidate "$1")
  [ -d "$capture_session" ] || capture_die 'session directory does not exist'
  [ ! -L "$capture_session" ] || capture_die 'session directory must not be a symlink'
  capture_session=$(CDPATH='' cd -P "$capture_session" && pwd)
  capture_require_outside_git "$capture_session" >/dev/null
  [ -f "$capture_session/.openglucose-passive-capture" ] || capture_die 'session sentinel is missing'
  [ ! -L "$capture_session/.openglucose-passive-capture" ] || capture_die 'session sentinel must not be a symlink'
  capture_package=$(sed -n 's/^package=//p' "$capture_session/session.properties")
  capture_expected_device=$(sed -n 's/^device_serial_sha256=//p' "$capture_session/session.properties")
  capture_expected_android_user_id=$(sed -n 's/^android_user_id=//p' "$capture_session/session.properties")
  capture_profile=$(sed -n 's/^capture_profile=//p' "$capture_session/session.properties")
  [ -n "$capture_profile" ] || capture_profile=libre
  [ "$capture_profile" = "$capture_requested_profile" ] ||
    capture_die 'capture profile does not match this session'
  capture_live_aidex=$(sed -n 's/^capture_live_aidex=//p' "$capture_session/session.properties")
  case "$capture_live_aidex" in
    true | false) ;;
    *) capture_die 'capture live-AiDEX session binding is missing or invalid' ;;
  esac
  [ "$capture_live_aidex" = "$capture_requested_live_aidex" ] ||
    capture_die 'capture live-AiDEX mode does not match this session'
  capture_validate_package "$capture_package"
  capture_validate_android_user_id "$capture_expected_android_user_id"
}

capture_require_matching_device() {
  capture_select_device
  capture_current_device=$(capture_sha256_text "$capture_serial")
  [ "$capture_current_device" = "$capture_expected_device" ] ||
    capture_die 'the selected device does not match this session'
  capture_require_matching_android_user
}

capture_record_marker() {
  capture_marker=$1
  capture_adb_call shell -n log -p i -t OpenGlucoseCapture "$capture_marker" >/dev/null
}

capture_require_active_logcat() {
  [ "$(sed -n '1p' "$capture_session/state")" = active ] || capture_die 'session is not active'
  capture_pid=$(sed -n '1p' "$capture_session/logcat.pid")
  capture_expected=$(sed -n '1p' "$capture_session/logcat.fingerprint")
  case "$capture_pid" in *[!0-9]* | '') capture_die 'invalid logcat PID' ;; esac
  capture_actual=$(capture_process_fingerprint "$capture_pid" || :)
  [ "$capture_actual" = "$capture_expected" ] || capture_die 'session logcat process is not alive or changed identity'
}

capture_text_artifact() {
  capture_destination=$1
  shift
  capture_temp=$capture_destination.pending
  if [ "${1:-}" = shell ]; then
    shift
    capture_text_status=0
    capture_adb_call shell -n "$@" >"$capture_temp" 2>"$capture_destination.stderr" ||
      capture_text_status=$?
  else
    capture_text_status=0
    capture_adb_call "$@" >"$capture_temp" 2>"$capture_destination.stderr" ||
      capture_text_status=$?
  fi
  if [ "$capture_text_status" -eq 0 ]; then
    mv "$capture_temp" "$capture_destination"
    rm -f "$capture_destination.stderr"
    chmod 600 "$capture_destination"
    return 0
  fi
  rm -f "$capture_temp"
  chmod 600 "$capture_destination.stderr"
  return 1
}

capture_run_as_text_artifact() {
  capture_destination=$1
  capture_run_as_package=$2
  shift 2
  capture_require_matching_android_user
  capture_text_artifact "$capture_destination" shell -T run-as \
    "$capture_run_as_package" --user "$capture_expected_android_user_id" "$@"
}

capture_export_status_bound_traces() {
  capture_destination=$1
  mkdir -p "$capture_destination"
  chmod 700 "$capture_destination"
  capture_status_file=$capture_destination/capture-status.json
  if ! capture_run_as_call "$capture_package" cat files/protocol-captures/capture-status.json >"$capture_status_file" 2>"$capture_destination/status.txt"; then
    rm -f "$capture_status_file"
    printf '%s\n' 'unavailable: exact app capture status could not be read' >"$capture_destination/status.txt"
    chmod 600 "$capture_destination/status.txt"
    return 0
  fi
  chmod 600 "$capture_status_file"
  capture_selection=$capture_destination/selection.properties
  if ! ruby -rjson -e '
    value = JSON.parse(File.read(ARGV.fetch(0)))
    required = %w[
      activityResumed bleTraceFileName bleTraceSessionId capacityReached
      heartbeatAtUtc heartbeatMonotonicMicroseconds lastCommittedBleRecordedAtUtc
      lastCommittedBleSequence lastUpdateTime nativeCaptureSessionId
      nativeCaptureWritable nfcTraceFileName processId processSessionId
      rfPointOfUseEligible scannerServiceUuids scannerState schemaVersion
      sinkErrorCode sinkState statusCommittedAtElapsedRealtimeNanos
      statusCommittedAtUtc stopping versionCode
    ].sort
    token = /\A[A-Za-z0-9_-]{8,160}\z/
    valid = value.is_a?(Hash) && value.keys.sort == required &&
      value["schemaVersion"] == 2 &&
      value["nativeCaptureSessionId"].is_a?(String) && value["nativeCaptureSessionId"].match?(token) &&
      value["processSessionId"].is_a?(String) && value["processSessionId"].match?(token) &&
      value["bleTraceSessionId"].is_a?(String) && value["bleTraceSessionId"].match?(token) &&
      value["processId"].is_a?(Integer) && value["processId"] > 0
    if valid
      native = value.fetch("nativeCaptureSessionId")
      ble = value.fetch("bleTraceSessionId")
      nfc_file = value["nfcTraceFileName"]
      ble_file = value["bleTraceFileName"]
      valid = nfc_file.is_a?(String) &&
        nfc_file.match?(/\Anfc-#{Regexp.escape(native)}-[0-9a-f]{32}\.jsonl\z/) &&
        (ble_file.nil? || (ble_file.is_a?(String) &&
          ble_file.match?(/\Able-#{Regexp.escape(ble)}-[0-9]{2}\.jsonl\z/)))
    end
    abort "unsafe or malformed status-bound trace names" unless valid
    File.open(ARGV.fetch(1), "w", 0o600) do |file|
      file.puts "native_session=#{native}"
      file.puts "process_session=#{value.fetch("processSessionId")}"
      file.puts "process_id=#{value.fetch("processId")}"
      file.puts "ble_session=#{ble}"
      file.puts "ble_file=#{ble_file || "unavailable"}"
      file.puts "nfc_file=#{nfc_file}"
    end
  ' "$capture_status_file" "$capture_selection"; then
    printf '%s\n' 'unavailable: status-bound trace names failed strict validation' >"$capture_destination/status.txt"
    chmod 600 "$capture_destination/status.txt"
    return 0
  fi
  chmod 600 "$capture_selection"
  capture_nfc_file=$(sed -n 's/^nfc_file=//p' "$capture_selection")
  capture_ble_session=$(sed -n 's/^ble_session=//p' "$capture_selection")
  capture_ble_current=$(sed -n 's/^ble_file=//p' "$capture_selection")
  capture_collected=0
  capture_nfc_destination=$capture_destination/$capture_nfc_file
  if capture_run_as_call "$capture_package" cat "files/protocol-captures/$capture_nfc_file" >"$capture_nfc_destination" 2>/dev/null; then
    chmod 600 "$capture_nfc_destination"
    capture_collected=$((capture_collected + 1))
  else
    rm -f "$capture_nfc_destination"
  fi
  capture_ble_current_collected=false
  capture_segment=0
  while [ "$capture_segment" -lt 8 ]; do
    capture_ble_file=$(printf 'ble-%s-%02d.jsonl' "$capture_ble_session" "$capture_segment")
    capture_ble_destination=$capture_destination/$capture_ble_file
    if capture_run_as_call "$capture_package" cat "files/protocol-captures/$capture_ble_file" >"$capture_ble_destination" 2>/dev/null; then
      chmod 600 "$capture_ble_destination"
      capture_collected=$((capture_collected + 1))
      [ "$capture_ble_file" != "$capture_ble_current" ] || capture_ble_current_collected=true
    else
      rm -f "$capture_ble_destination"
    fi
    capture_segment=$((capture_segment + 1))
  done
  if [ "$capture_ble_current" != unavailable ] && [ "$capture_ble_current_collected" != true ]; then
    printf '%s\n' 'incomplete: exact current BLE segment was not exportable' >"$capture_destination/status.txt"
  else
    printf 'collected=%s\n' "$capture_collected" >"$capture_destination/status.txt"
  fi
  chmod 600 "$capture_destination/status.txt"
}

capture_append_app_offsets() {
  capture_app_directory=$1
  capture_metadata_file=$2
  capture_offsets_file=$capture_app_directory/offsets.txt
  capture_app_file_count=0
  capture_app_total_bytes=0
  capture_nfc_last_sequence=unavailable
  capture_ble_last_sequence=unavailable
  : >"$capture_offsets_file"
  for capture_app_file in "$capture_app_directory"/*.jsonl; do
    [ -f "$capture_app_file" ] || continue
    [ "${capture_app_file##*/}" != capture-status.json ] || continue
    capture_app_file_count=$((capture_app_file_count + 1))
    capture_app_bytes=$(wc -c <"$capture_app_file" | tr -d ' ')
    capture_app_lines=$(wc -l <"$capture_app_file" | tr -d ' ')
    capture_app_total_bytes=$((capture_app_total_bytes + capture_app_bytes))
    capture_app_sequence=$(tail -n 1 "$capture_app_file" | ruby -rjson -e '
      value = JSON.parse(STDIN.read)["sequence"] rescue nil
      puts(value.is_a?(Integer) && value >= 0 ? value : "unavailable")
    ')
    case "${capture_app_file##*/}:$capture_app_sequence" in
      nfc-*:*[!0-9]* | nfc-*:) ;;
      nfc-*:*) capture_nfc_last_sequence=$capture_app_sequence ;;
      ble-*:*[!0-9]* | ble-*:) ;;
      ble-*:*) capture_ble_last_sequence=$capture_app_sequence ;;
    esac
    printf '%s bytes=%s lines=%s last_sequence=%s\n' \
      "${capture_app_file##*/}" "$capture_app_bytes" "$capture_app_lines" "$capture_app_sequence" >>"$capture_offsets_file"
  done
  {
    printf 'app_jsonl_file_count=%s\n' "$capture_app_file_count"
    printf 'app_jsonl_total_byte_offset=%s\n' "$capture_app_total_bytes"
    printf 'nfc_last_sequence=%s\n' "$capture_nfc_last_sequence"
    printf 'ble_last_sequence=%s\n' "$capture_ble_last_sequence"
  } >>"$capture_metadata_file"
  chmod 600 "$capture_offsets_file"
}

capture_write_hashes() {
  capture_hash_root=$1
  capture_hash_temp=$capture_hash_root/hashes.sha256.pending
  (
    CDPATH='' cd "$capture_hash_root"
    find . -type f ! -name 'hashes.sha256' ! -name 'hashes.sha256.pending' -print |
      LC_ALL=C sort | while IFS= read -r capture_hash_path; do
        capture_hash=$(capture_sha256_file "$capture_hash_path")
        printf '%s  %s\n' "$capture_hash" "${capture_hash_path#./}"
      done
  ) >"$capture_hash_temp"
  mv "$capture_hash_temp" "$capture_hash_root/hashes.sha256"
  chmod 600 "$capture_hash_root/hashes.sha256"
}

capture_next_snapshot_dir() {
  capture_label=$1
  capture_index=1
  while :; do
    capture_snapshot=$(printf '%s/snapshots/%04d-%s' "$capture_session" "$capture_index" "$capture_label")
    if mkdir "$capture_snapshot" 2>/dev/null; then
      chmod 700 "$capture_snapshot"
      printf '%s\n' "$capture_snapshot"
      return 0
    fi
    capture_index=$((capture_index + 1))
    [ "$capture_index" -le 9999 ] || capture_die 'snapshot index is exhausted'
  done
}

capture_snapshot_impl() {
  capture_label=$1
  capture_validate_label "$capture_label"
  capture_require_active_logcat
  capture_snapshot=$(capture_next_snapshot_dir "$capture_label")
  capture_snapshot_id=${capture_snapshot##*/}
  capture_record_marker "session=${capture_session##*/} event=snapshot-begin state=$capture_label"
  capture_failures=0
  capture_logcat_offset=$(wc -c <"$capture_session/logcat-all.txt" | tr -d ' ')
  {
    printf 'captured_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'host_monotonic_nanos=%s\n' "$(capture_host_monotonic_nanos)"
    printf 'state_label=%s\n' "$capture_label"
    printf 'package=%s\n' "$capture_package"
    printf 'logcat_byte_offset=%s\n' "$capture_logcat_offset"
    printf '%s\n' 'hci_byte_offset=unavailable'
    printf '%s\n' 'operator_observation=omitted-no-free-text-contract'
  } >"$capture_snapshot/metadata.txt"
  chmod 600 "$capture_snapshot/metadata.txt"
  capture_text_artifact "$capture_snapshot/device-clock.txt" shell date '+%Y-%m-%dT%H:%M:%S%z' || capture_failures=$((capture_failures + 1))
  capture_text_artifact "$capture_snapshot/ui.xml" exec-out uiautomator dump /dev/tty || capture_failures=$((capture_failures + 1))
  capture_text_artifact "$capture_snapshot/bluetooth.txt" shell dumpsys bluetooth_manager || capture_failures=$((capture_failures + 1))
  capture_text_artifact "$capture_snapshot/nfc.txt" shell dumpsys nfc || capture_failures=$((capture_failures + 1))
  capture_text_artifact "$capture_snapshot/activity.txt" shell dumpsys activity activities || capture_failures=$((capture_failures + 1))
  capture_text_artifact "$capture_snapshot/window.txt" shell dumpsys window windows || capture_failures=$((capture_failures + 1))
  capture_text_artifact "$capture_snapshot/package.txt" shell dumpsys package "$capture_package" || capture_failures=$((capture_failures + 1))
  capture_text_artifact "$capture_snapshot/screen.png" exec-out screencap -p || capture_failures=$((capture_failures + 1))
  capture_hci_status "$capture_snapshot/hci-snoop-status.txt" >/dev/null
  capture_export_status_bound_traces "$capture_snapshot/app-jsonl"
  capture_append_app_offsets "$capture_snapshot/app-jsonl" "$capture_snapshot/metadata.txt"
  capture_record_marker "session=${capture_session##*/} event=snapshot-end state=$capture_label failures=$capture_failures"
  capture_write_hashes "$capture_snapshot"
  printf '%s\n' "$capture_snapshot"
  [ "$capture_failures" -eq 0 ] || capture_die "snapshot $capture_snapshot_id is incomplete; inspect .stderr files"
}

capture_doctor() {
  capture_output_root=$capture_default_root
  capture_package=$capture_default_package
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output-root) [ "$#" -ge 2 ] || capture_die '--output-root needs a value'; capture_output_root=$2; shift 2 ;;
      --package) [ "$#" -ge 2 ] || capture_die '--package needs a value'; capture_package=$2; shift 2 ;;
      --help | -h) capture_usage; exit 0 ;;
      *) capture_die "unknown doctor option: $1" ;;
    esac
  done
  capture_validate_package "$capture_package"
  capture_require_command ruby
  capture_root=$(capture_prepare_root "$capture_output_root")
  capture_select_device
  capture_detect_android_user
  capture_temp=$(mktemp "$capture_root/.doctor-hci.XXXXXX")
  capture_hci=$(capture_hci_status "$capture_temp")
  rm -f "$capture_temp"
  [ "$capture_hci" = full ] || capture_die "full HCI snoop configuration is not verified (status: $capture_hci)"
  printf '%s\n' 'DEVICE READY: one authorized device; output is outside Git; full HCI snoop setting is reported.'
  printf '%s\n' 'This verifies settings only. Use a bugreport to attempt collection of the OEM-provided HCI artifact.'
}

capture_start() {
  capture_output_root=$capture_default_root
  capture_package=$capture_default_package
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output-root) [ "$#" -ge 2 ] || capture_die '--output-root needs a value'; capture_output_root=$2; shift 2 ;;
      --package) [ "$#" -ge 2 ] || capture_die '--package needs a value'; capture_package=$2; shift 2 ;;
      *) capture_die "unknown start option: $1" ;;
    esac
  done
  capture_validate_package "$capture_package"
  capture_require_command ruby
  capture_root=$(capture_prepare_root "$capture_output_root")
  capture_select_device
  capture_detect_android_user
  capture_expected_android_user_id=$capture_android_user_id
  capture_expected_device=$(capture_sha256_text "$capture_serial")
  if [ "$capture_package" = com.openglucose.app.debug ]; then
    capture_require_debug_app_stopped_for_start
    capture_run_as_call "$capture_package" mkdir -p files/protocol-captures ||
      capture_die 'could not create the app-private protocol-captures directory'
    capture_run_as_call "$capture_package" chmod 700 files/protocol-captures ||
      capture_die 'could not protect the app-private protocol-captures directory'
    capture_arm_cleanup_device=false
    trap capture_cleanup_start EXIT
    trap 'exit 130' HUP INT TERM
    capture_acquire_arm_rf_lease
    capture_remove_target_unverified_grants ||
      capture_die 'could not durably clean stale target-unverified NFC grants before start'
  fi
  capture_require_matching_android_user
  capture_stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  capture_session=$(mktemp -d "$capture_root/session-$capture_stamp-XXXXXX")
  chmod 700 "$capture_session"
  mkdir -p "$capture_session/snapshots" "$capture_session/reports"
  chmod 700 "$capture_session/snapshots" "$capture_session/reports"
  printf '%s\n' 'schema=1' >"$capture_session/.openglucose-passive-capture"
  capture_device_hash=$capture_expected_device
  if [ "$capture_requested_live_aidex" = true ]; then
    capture_session_mode=full-ui-live-aidex-plus-protocol-capture
  else
    capture_session_mode=passive-until-separately-armed
  fi
  {
    printf '%s\n' 'schema=1'
    printf 'session_id=%s\n' "${capture_session##*/}"
    printf 'created_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'package=%s\n' "$capture_package"
    printf 'device_serial_sha256=%s\n' "$capture_device_hash"
    printf 'android_user_id=%s\n' "$capture_expected_android_user_id"
    printf 'capture_profile=%s\n' "$capture_requested_profile"
    printf 'capture_live_aidex=%s\n' "$capture_requested_live_aidex"
    printf 'mode=%s\n' "$capture_session_mode"
  } >"$capture_session/session.properties"
  chmod 600 "$capture_session/.openglucose-passive-capture" "$capture_session/session.properties"
  capture_hci=$(capture_hci_status "$capture_session/hci-snoop-status.txt")
  [ "$capture_hci" = full ] || capture_die "full HCI snoop configuration is not verified (status: $capture_hci)"
  printf '%s\n' active >"$capture_session/state"
  chmod 600 "$capture_session/state"
  ANDROID_SERIAL=$capture_serial "$capture_adb" logcat -b all -v epoch -T 1 >"$capture_session/logcat-all.txt" 2>"$capture_session/logcat.stderr" &
  capture_pid=$!
  capture_cleanup_pid=$capture_pid
  capture_cleanup_session=$capture_session
  trap capture_cleanup_start EXIT
  trap 'exit 130' HUP INT TERM
  printf '%s\n' "$capture_pid" >"$capture_session/logcat.pid"
  chmod 600 "$capture_session/logcat.pid" "$capture_session/logcat-all.txt" "$capture_session/logcat.stderr"
  sleep 1
  capture_fingerprint=$(capture_process_fingerprint "$capture_pid" || :)
  [ -n "$capture_fingerprint" ] || capture_die 'all-buffer logcat did not remain active'
  printf '%s\n' "$capture_fingerprint" >"$capture_session/logcat.fingerprint"
  chmod 600 "$capture_session/logcat.fingerprint"
  capture_cleanup_fingerprint=$capture_fingerprint
  capture_record_marker \
    "session=${capture_session##*/} event=start live_aidex=$capture_requested_live_aidex"
  capture_snapshot_impl 00-baseline-phone >/dev/null
  if [ "$capture_package" = com.openglucose.app.debug ]; then
    capture_release_arm_rf_lease ||
      capture_die 'could not release the app-private NFC RF lease after start'
  fi
  capture_cleanup_pid=
  capture_cleanup_fingerprint=
  capture_cleanup_session=
  trap - EXIT HUP INT TERM
  printf '%s\n' "$capture_session"
}

capture_snapshot_command() {
  capture_session_arg=
  capture_label=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || capture_die '--session needs a value'; capture_session_arg=$2; shift 2 ;;
      --label) [ "$#" -ge 2 ] || capture_die '--label needs a value'; capture_label=$2; shift 2 ;;
      *) capture_die "unknown snapshot option: $1" ;;
    esac
  done
  [ -n "$capture_session_arg" ] || capture_die '--session is required'
  [ -n "$capture_label" ] || capture_die '--label is required'
  capture_require_session "$capture_session_arg"
  capture_require_matching_device
  capture_snapshot_impl "$capture_label"
}

capture_next_readiness_dir() {
  capture_readiness_index=1
  mkdir -p "$capture_session/readiness"
  chmod 700 "$capture_session/readiness"
  while :; do
    capture_readiness_dir=$(printf '%s/readiness/%04d' "$capture_session" "$capture_readiness_index")
    if mkdir "$capture_readiness_dir" 2>/dev/null; then
      chmod 700 "$capture_readiness_dir"
      return 0
    fi
    capture_readiness_index=$((capture_readiness_index + 1))
    [ "$capture_readiness_index" -le 9999 ] || capture_die 'readiness evidence index is exhausted'
  done
}

capture_verify_app_ready_impl() {
  capture_next_readiness_dir
  capture_status_path=files/protocol-captures/capture-status.json
  capture_sample_one=$capture_readiness_dir/status-1.json
  capture_sample_two=$capture_readiness_dir/status-2.json
  capture_pid_one=$(capture_read_value shell pidof "$capture_package")
  printf '%s\n' "$capture_pid_one" | grep -Eq '^[0-9]+$' ||
    capture_die 'the debug package does not have exactly one current process'
  capture_run_as_text_artifact "$capture_sample_one" "$capture_package" cat "$capture_status_path" ||
    capture_die 'the first app-owned schema-v2 status sample is unavailable'
  sleep 3
  capture_pid_two=$(capture_read_value shell pidof "$capture_package")
  [ "$capture_pid_two" = "$capture_pid_one" ] ||
    capture_die 'the debug package process changed during readiness sampling'
  capture_run_as_text_artifact "$capture_sample_two" "$capture_package" cat "$capture_status_path" ||
    capture_die 'the second app-owned schema-v2 status sample is unavailable'
  capture_package_dump=$capture_readiness_dir/package.txt
  capture_text_artifact "$capture_package_dump" shell dumpsys package "$capture_package" ||
    capture_die 'current package state is unavailable'
  capture_phone_now=$(capture_read_value shell date '+%s%3N')
  capture_phone_zone=$(capture_read_value shell date '+%z')
  printf '%s\n' "$capture_phone_now" | grep -Eq '^[0-9]{13}$' ||
    capture_die 'the phone did not provide a strict epoch-millisecond clock'
  printf '%s\n' "$capture_phone_zone" | grep -Eq '^[+-][0-9]{4}$' ||
    capture_die 'the phone did not provide a strict numeric timezone'
  capture_selection=$capture_readiness_dir/selection.properties
  if ! ruby -rjson -rtime -e '
    first = JSON.parse(File.read(ARGV.fetch(0)))
    second = JSON.parse(File.read(ARGV.fetch(1)))
    package_dump = File.read(ARGV.fetch(2))
    pid = Integer(ARGV.fetch(3), 10)
    now_ms = Integer(ARGV.fetch(4), 10)
    zone = ARGV.fetch(5)
    keys = %w[
      activityResumed bleTraceFileName bleTraceSessionId capacityReached
      heartbeatAtUtc heartbeatMonotonicMicroseconds lastCommittedBleRecordedAtUtc
      lastCommittedBleSequence lastUpdateTime nativeCaptureSessionId
      nativeCaptureWritable nfcTraceFileName processId processSessionId
      rfPointOfUseEligible scannerServiceUuids scannerState schemaVersion
      sinkErrorCode sinkState statusCommittedAtElapsedRealtimeNanos
      statusCommittedAtUtc stopping versionCode
    ].sort
    token = /\A[A-Za-z0-9_-]{8,160}\z/
    canonical_uuid = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    profile = ARGV.fetch(7)
    live_aidex = ARGV.fetch(8)
    fde3 = "0000fde3-0000-1000-8000-00805f9b34fb"
    aidex_cgm = "0000181f-0000-1000-8000-00805f9b34fb"
    expected_services =
      if profile == "libre"
        live_aidex == "true" ? [fde3, aidex_cgm] : [fde3]
      elsif profile == "yuwell_anytime_passive"
        []
      end
    parse_ms = ->(text) { (Time.iso8601(text).to_r * 1000).to_i rescue nil }
    healthy = lambda do |value|
      value.is_a?(Hash) && value.keys.sort == keys && value["schemaVersion"] == 2 &&
        value["processId"] == pid && value["versionCode"].is_a?(Integer) && value["versionCode"] > 0 &&
        value["lastUpdateTime"].is_a?(Integer) && value["lastUpdateTime"] > 0 &&
        value["nativeCaptureSessionId"].is_a?(String) && value["nativeCaptureSessionId"].match?(token) &&
        value["processSessionId"].is_a?(String) && value["processSessionId"].match?(token) &&
        value["bleTraceSessionId"].is_a?(String) && value["bleTraceSessionId"].match?(token) &&
        value["scannerState"] == "running" && value["sinkState"] == "healthy" &&
        value["nativeCaptureWritable"] == true && value["capacityReached"] == false &&
        value["sinkErrorCode"].nil? && value["stopping"] == false &&
        value["activityResumed"] == true && value["rfPointOfUseEligible"] == true &&
        value["scannerServiceUuids"].is_a?(Array) &&
        value["scannerServiceUuids"].all? { |uuid| uuid.is_a?(String) && uuid.match?(canonical_uuid) } &&
        !expected_services.nil? && value["scannerServiceUuids"] == expected_services &&
        value["lastCommittedBleSequence"].is_a?(Integer) && value["lastCommittedBleSequence"] > 0 &&
        value["heartbeatMonotonicMicroseconds"].is_a?(Integer) && value["heartbeatMonotonicMicroseconds"] > 0 &&
        value["statusCommittedAtElapsedRealtimeNanos"].is_a?(Integer) &&
        value["statusCommittedAtElapsedRealtimeNanos"] > 0
    end
    valid = healthy.call(first) && healthy.call(second)
    identity_keys = %w[nativeCaptureSessionId processId processSessionId bleTraceSessionId versionCode lastUpdateTime]
    valid &&= identity_keys.all? { |key| first[key] == second[key] }
    if valid
      native = second.fetch("nativeCaptureSessionId")
      ble = second.fetch("bleTraceSessionId")
      nfc_file = second["nfcTraceFileName"]
      ble_file = second["bleTraceFileName"]
      valid &&= nfc_file.is_a?(String) &&
        nfc_file.match?(/\Anfc-#{Regexp.escape(native)}-[0-9a-f]{32}\.jsonl\z/) &&
        ble_file.is_a?(String) && ble_file.match?(/\Able-#{Regexp.escape(ble)}-[0-9]{2}\.jsonl\z/)
      valid &&= second["statusCommittedAtElapsedRealtimeNanos"] > first["statusCommittedAtElapsedRealtimeNanos"] &&
        second["statusCommittedAtElapsedRealtimeNanos"] - first["statusCommittedAtElapsedRealtimeNanos"] >= 2_000_000_000 &&
        second["statusCommittedAtElapsedRealtimeNanos"] - first["statusCommittedAtElapsedRealtimeNanos"] <= 10_000_000_000 &&
        second["heartbeatMonotonicMicroseconds"] > first["heartbeatMonotonicMicroseconds"] &&
        second["lastCommittedBleSequence"] > first["lastCommittedBleSequence"]
      first_ble_commit = first["lastCommittedBleRecordedAtUtc"].is_a?(String) ? parse_ms.call(first["lastCommittedBleRecordedAtUtc"]) : nil
      second_ble_commit = second["lastCommittedBleRecordedAtUtc"].is_a?(String) ? parse_ms.call(second["lastCommittedBleRecordedAtUtc"]) : nil
      valid &&= !first_ble_commit.nil? && !second_ble_commit.nil? && second_ble_commit > first_ble_commit
      %w[statusCommittedAtUtc heartbeatAtUtc lastCommittedBleRecordedAtUtc].each do |key|
        timestamp_ms = second[key].is_a?(String) ? parse_ms.call(second[key]) : nil
        age = timestamp_ms.nil? ? nil : now_ms - timestamp_ms
        valid &&= !age.nil? && age >= -5_000 && age <= 6_000
      end
      version_match = package_dump.match(/\bversionCode=(\d+)\b/)
      update_match = package_dump.match(/\blastUpdateTime=(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/)
      package_update_ms = update_match.nil? ? nil :
        (Time.strptime("#{update_match[1]} #{zone}", "%Y-%m-%d %H:%M:%S %z").to_r * 1000).to_i
      valid &&= !version_match.nil? && version_match[1].to_i == second["versionCode"] &&
        !package_update_ms.nil? && package_update_ms / 1000 == second["lastUpdateTime"] / 1000
    end
    abort "schema-v2 readiness samples are not current, healthy, bound, and advancing" unless valid
    File.open(ARGV.fetch(6), "w", 0o600) do |file|
      file.puts "native_session=#{second.fetch("nativeCaptureSessionId")}"
      file.puts "process_session=#{second.fetch("processSessionId")}"
      file.puts "process_id=#{second.fetch("processId")}"
      file.puts "version_code=#{second.fetch("versionCode")}"
      file.puts "last_update_time=#{second.fetch("lastUpdateTime")}"
      file.puts "ble_session=#{second.fetch("bleTraceSessionId")}"
      file.puts "ble_file=#{second.fetch("bleTraceFileName")}"
      file.puts "nfc_file=#{second.fetch("nfcTraceFileName")}"
      file.puts "capture_live_aidex=#{live_aidex}"
    end
  ' "$capture_sample_one" "$capture_sample_two" "$capture_package_dump" "$capture_pid_two" \
    "$capture_phone_now" "$capture_phone_zone" "$capture_selection" "$capture_profile" \
    "$capture_live_aidex"; then
    capture_write_hashes "$capture_readiness_dir"
    capture_die 'app capture failed exact two-sample schema-v2 readiness'
  fi
  chmod 600 "$capture_selection"
  capture_export_status_bound_traces "$capture_readiness_dir/traces"
  capture_selection=$capture_readiness_dir/selection.properties
  capture_write_hashes "$capture_readiness_dir"
}

capture_verify_app_ready_command() {
  capture_session_arg=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || capture_die '--session needs a value'; capture_session_arg=$2; shift 2 ;;
      *) capture_die "unknown verify-app-ready option: $1" ;;
    esac
  done
  [ -n "$capture_session_arg" ] || capture_die '--session is required'
  capture_require_session "$capture_session_arg"
  [ "$capture_package" = com.openglucose.app.debug ] ||
    capture_die 'app capture readiness is restricted to com.openglucose.app.debug'
  capture_require_matching_device
  capture_require_active_logcat
  capture_verify_app_ready_impl
  capture_record_marker "session=${capture_session##*/} event=app-capture-ready-verified schema=2"
  printf '%s\n' 'APP CAPTURE READY: two schema-v2 samples are current, bound, healthy, and advancing.'
  printf '%s\n' 'This is capture readiness only; it is not approval to contact a sensor.'
}

capture_validate_target_observation() {
  capture_target_file=$1
  capture_selection_file=$2
  capture_phone_now=$3
  ruby -rjson -rtime -e '
    target = JSON.parse(File.read(ARGV.fetch(0)))
    selected = File.readlines(ARGV.fetch(1), chomp: true).to_h { |line| line.split("=", 2) }
    keys = %w[schemaVersion nativeCaptureSessionId processSessionId targetUidSha256 iso15693ManufacturerPrefix observedAtUtc observedAtMonotonicElapsedNanos].sort
    now_ms = Integer(ARGV.fetch(2), 10)
    observed_ms = (Time.iso8601(target["observedAtUtc"]).to_r * 1000).to_i rescue nil
    valid = target.is_a?(Hash) && target.keys.sort == keys && target["schemaVersion"] == 1 &&
      target["nativeCaptureSessionId"] == selected["native_session"] &&
      target["processSessionId"] == selected["process_session"] &&
      target["targetUidSha256"].is_a?(String) && target["targetUidSha256"].match?(/\A[0-9a-f]{64}\z/) &&
      target["iso15693ManufacturerPrefix"] == "e007" &&
      target["observedAtMonotonicElapsedNanos"].is_a?(Integer) && target["observedAtMonotonicElapsedNanos"] > 0 &&
      !observed_ms.nil? && now_ms - observed_ms >= -5_000 && now_ms - observed_ms <= 120_000
    abort "target observation is malformed, stale, or not bound to current capture identities" unless valid
  ' "$capture_target_file" "$capture_selection_file" "$capture_phone_now"
}

capture_verify_target_observation_command() {
  capture_session_arg=
  capture_reference_ack=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || capture_die '--session needs a value'; capture_session_arg=$2; shift 2 ;;
      --ack-reference-e007-target-unverified) capture_reference_ack=true; shift ;;
      *) capture_die "unknown verify-target-observation option: $1" ;;
    esac
  done
  [ -n "$capture_session_arg" ] || capture_die '--session is required'
  [ "$capture_reference_ack" = true ] ||
    capture_die 'verification requires --ack-reference-e007-target-unverified'
  capture_require_session "$capture_session_arg"
  [ "$capture_profile" = libre ] ||
    capture_die 'Libre NFC target observation is disabled for this capture profile'
  [ "$capture_package" = com.openglucose.app.debug ] || capture_die 'target observation verification is debug-only'
  capture_require_matching_device
  capture_require_active_logcat
  capture_target=files/protocol-captures/nfc-target-context.json
  capture_observation=$capture_session/target-observation.json
  capture_observation_pending=$capture_observation.pending
  capture_observation_stderr=$capture_observation.stderr
  capture_observation_validation_stderr=$capture_observation.validation.stderr
  capture_observation_hash=$capture_session/target-observation.sha256
  capture_observation_hash_pending=$capture_observation_hash.pending
  rm -f "$capture_observation" "$capture_observation_pending" \
    "$capture_observation_hash" "$capture_observation_hash_pending" \
    "$capture_observation_stderr" "$capture_observation_validation_stderr"
  capture_verify_app_ready_impl
  if ! capture_run_as_call "$capture_package" cat "$capture_target" \
    >"$capture_observation_pending" 2>"$capture_observation_stderr"; then
    rm -f "$capture_observation_pending"
    chmod 600 "$capture_observation_stderr"
    capture_die 'current app-owned target observation is unavailable'
  fi
  chmod 600 "$capture_observation_pending"
  rm -f "$capture_observation_stderr"
  capture_phone_now=$(capture_read_value shell date '+%s%3N')
  if ! printf '%s\n' "$capture_phone_now" | grep -Eq '^[0-9]{13}$'; then
    rm -f "$capture_observation_pending"
    capture_die 'phone clock is unavailable'
  fi
  if ! capture_validate_target_observation \
    "$capture_observation_pending" "$capture_selection" "$capture_phone_now" \
    2>"$capture_observation_validation_stderr"; then
    rm -f "$capture_observation_pending"
    chmod 600 "$capture_observation_validation_stderr"
    capture_die 'target observation verification failed'
  fi
  rm -f "$capture_observation_validation_stderr"
  if ! capture_sha256_file "$capture_observation_pending" >"$capture_observation_hash_pending"; then
    rm -f "$capture_observation_pending" "$capture_observation_hash_pending"
    capture_die 'target observation integrity hash failed'
  fi
  chmod 600 "$capture_observation_hash_pending"
  mv "$capture_observation_pending" "$capture_observation"
  mv "$capture_observation_hash_pending" "$capture_observation_hash"
  printf '%s\n' 'TARGET OBSERVATION VERIFIED: e007 matches reference evidence only; physical model compatibility is not proven.'
}

capture_nfc_arm_command() {
  capture_nfc_action=$1
  shift
  capture_session_arg=
  capture_r3_target_ack=false
  capture_r3_gen1_fram_ack=false
  capture_r3_gen1_activation_ack=false
  capture_reuse_verified_target_ack=false
  capture_source_session_arg=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || capture_die '--session needs a value'; capture_session_arg=$2; shift 2 ;;
      --ack-r3-target-unverified) capture_r3_target_ack=true; shift ;;
      --ack-r3-gen1-fram-read) capture_r3_gen1_fram_ack=true; shift ;;
      --ack-r3-gen1-activation) capture_r3_gen1_activation_ack=true; shift ;;
      --ack-reuse-verified-target) capture_reuse_verified_target_ack=true; shift ;;
      --source-session) [ "$#" -ge 2 ] || capture_die '--source-session needs a value'; capture_source_session_arg=$2; shift 2 ;;
      *) capture_die "unknown $capture_nfc_action option: $1" ;;
    esac
  done
  [ -n "$capture_session_arg" ] || capture_die '--session is required'
  capture_require_session "$capture_session_arg"
  [ "$capture_profile" = libre ] ||
    capture_die 'Libre NFC probing is disabled for this capture profile'
  [ "$capture_package" = com.openglucose.app.debug ] ||
    capture_die 'target-unverified NFC arming is restricted to com.openglucose.app.debug'
  capture_require_matching_device
  capture_require_active_logcat
  capture_grant_context=files/protocol-captures/nfc-grant-context.json
  capture_target_context=files/protocol-captures/nfc-target-context.json
  capture_patch_context=files/protocol-captures/nfc-patch-info-context.json
  capture_requires_activation_source=false
  capture_reuses_verified_target=false
  case "$capture_nfc_action" in
    arm-target-unverified-nfc-probe)
      [ "$capture_r3_target_ack" = true ] ||
        capture_die 'arming requires the literal --ack-r3-target-unverified acknowledgement'
      capture_grant_path=files/protocol-captures/target-unverified-nfc-grant.json
      capture_grant_kind=target-unverified-nfc
      capture_arm_marker=target-unverified-nfc
      capture_requires_patch_context=false
      ;;
    arm-target-unverified-nfc-probe-from-verified-target)
      [ "$capture_r3_target_ack" = true ] ||
        capture_die 'arming requires the literal --ack-r3-target-unverified acknowledgement'
      [ "$capture_reuse_verified_target_ack" = true ] ||
        capture_die 'reused evidence requires the literal --ack-reuse-verified-target acknowledgement'
      [ -n "$capture_source_session_arg" ] || capture_die '--source-session is required for reused evidence'
      capture_grant_path=files/protocol-captures/target-unverified-nfc-grant.json
      capture_grant_kind=target-unverified-nfc
      capture_arm_marker=target-unverified-nfc-reused-target
      capture_requires_patch_context=false
      capture_reuses_verified_target=true
      ;;
    arm-target-unverified-gen1-fram-read)
      [ "$capture_r3_gen1_fram_ack" = true ] ||
        capture_die 'arming requires the literal --ack-r3-gen1-fram-read acknowledgement'
      capture_grant_path=files/protocol-captures/target-unverified-gen1-fram-read-grant.json
      capture_grant_kind=target-unverified-gen1-fram-read
      capture_arm_marker=target-unverified-gen1-fram-read
      capture_requires_patch_context=true
      capture_requires_activation_source=false
      ;;
    arm-target-unverified-gen1-activation)
      [ "$capture_r3_gen1_activation_ack" = true ] ||
        capture_die 'arming requires the literal --ack-r3-gen1-activation acknowledgement'
      capture_grant_path=files/protocol-captures/target-unverified-gen1-activation-grant.json
      capture_grant_kind=target-unverified-gen1-activation
      capture_arm_marker=target-unverified-gen1-activation
      capture_requires_patch_context=true
      capture_requires_activation_source=true
      ;;
    disarm-target-unverified-nfc-probe | disarm-target-unverified-gen1-fram-read | disarm-target-unverified-gen1-activation)
      capture_run_as_call "$capture_package" mkdir -p files/protocol-captures ||
        capture_die 'could not create the app-private protocol-captures directory'
      capture_run_as_call "$capture_package" chmod 700 files/protocol-captures ||
        capture_die 'could not protect the app-private protocol-captures directory'
      capture_arm_cleanup_device=false
      trap capture_cleanup_arm EXIT
      trap 'exit 130' HUP INT TERM
      capture_acquire_arm_rf_lease
      capture_record_marker "session=${capture_session##*/} event=target-unverified-nfc-all-grants-disarm-requested"
      if ! capture_remove_target_unverified_grants; then
        capture_die 'could not remove all app-private target-unverified NFC grants'
      fi
      capture_record_marker "session=${capture_session##*/} event=target-unverified-nfc-all-grants-disarmed"
      capture_release_arm_rf_lease ||
        capture_die 'could not release the app-private NFC RF lease after disarm'
      trap - EXIT HUP INT TERM
      printf '%s\n' 'disarmed: all target-unverified NFC grant and staging files'
      return 0
      ;;
    *) capture_die 'internal NFC arm action is invalid' ;;
  esac

  if [ "$capture_reuses_verified_target" = true ]; then
    capture_source_session=$(capture_canonical_candidate "$capture_source_session_arg")
    [ -d "$capture_source_session" ] && [ ! -L "$capture_source_session" ] ||
      capture_die 'source session directory is unavailable or unsafe'
    capture_source_session=$(CDPATH='' cd -P "$capture_source_session" && pwd)
    capture_require_outside_git "$capture_source_session" >/dev/null
    [ "$capture_source_session" != "$capture_session" ] ||
      capture_die 'reused target evidence must come from another capture session'
  else
    [ -z "$capture_source_session_arg" ] && [ "$capture_reuse_verified_target_ack" = false ] ||
      capture_die 'reused-target options are accepted only by the distinct reuse command'
    [ -f "$capture_session/target-observation.sha256" ] ||
      capture_die 'run verify-target-observation under the approved physical-model control first'
  fi
  capture_run_as_call "$capture_package" mkdir -p files/protocol-captures ||
    capture_die 'could not create the app-private protocol-captures directory'
  capture_run_as_call "$capture_package" chmod 700 files/protocol-captures ||
    capture_die 'could not protect the app-private protocol-captures directory'
  capture_arm_cleanup_device=false
  trap capture_cleanup_arm EXIT
  trap 'exit 130' HUP INT TERM
  capture_acquire_arm_rf_lease
  capture_arm_cleanup_device=true
  if [ "$capture_requires_activation_source" = true ]; then
    capture_activation_journal=files/protocol-captures/nfc-gen1-activation-journal.json
    if ! capture_run_as_call "$capture_package" test ! -e "$capture_activation_journal"; then
      capture_remove_target_unverified_grants >/dev/null 2>&1 || :
      capture_die 'an activation journal already exists; reviewed reconciliation is required before any retry'
    fi
    capture_activation_source=$capture_session/restricted/nfc-gen1-fram-capture.json
    capture_activation_source_hash_file=$capture_session/restricted/nfc-gen1-fram-capture.sha256
    [ -f "$capture_activation_source" ] && [ ! -L "$capture_activation_source" ] &&
      [ -f "$capture_activation_source_hash_file" ] && [ ! -L "$capture_activation_source_hash_file" ] ||
      capture_die 'collect and validate one private Gen1 FRAM capture before activation'
  fi
  capture_remove_target_unverified_grants || capture_die 'could not clean stale NFC grants'
  capture_verify_app_ready_impl
  capture_device_issued_at=$(capture_read_value shell date '+%s%3N')
  printf '%s\n' "$capture_device_issued_at" | grep -Eq '^[0-9]{13}$' ||
    capture_die 'the phone did not provide a strict 13-digit epoch-millisecond clock; refusing to arm'
  capture_record_marker "session=${capture_session##*/} event=${capture_arm_marker}-arm-requested risk=R3"
  capture_grant_temp_dir=$(mktemp -d "$capture_session/.grant-build-XXXXXX")
  chmod 700 "$capture_grant_temp_dir"
  if ! capture_run_as_call "$capture_package" cat "$capture_grant_context" >"$capture_grant_temp_dir/context.json"; then
    capture_die 'the app-owned NFC grant context is absent or unreadable'
  fi
  chmod 600 "$capture_grant_temp_dir/context.json"
  if [ "$capture_reuses_verified_target" = true ]; then
    if ! capture_build_reused_target_unverified_grant \
      "$capture_grant_temp_dir/context.json" \
      "$capture_source_session" \
      "$capture_selection" \
      "$capture_grant_temp_dir/grant.json" \
      "${capture_session##*/}" \
      "$capture_device_issued_at" \
      "$capture_expected_device" \
      "$capture_expected_android_user_id" \
      2>"$capture_grant_temp_dir/grant-validation.stderr"; then
      chmod 600 "$capture_grant_temp_dir/grant-validation.stderr"
      capture_die 'the prior verified target evidence is invalid or incompatible with this device'
    fi
  else
    if ! capture_run_as_call "$capture_package" cat "$capture_target_context" >"$capture_grant_temp_dir/target.json"; then
      capture_die 'the current app-owned NFC target context is absent or unreadable'
    fi
    chmod 600 "$capture_grant_temp_dir/target.json"
    [ "$(capture_sha256_file "$capture_grant_temp_dir/target.json")" = "$(sed -n '1p' "$capture_session/target-observation.sha256")" ] ||
      capture_die 'target observation changed after physical-model control; verify it again'
    capture_validate_target_observation "$capture_grant_temp_dir/target.json" "$capture_selection" "$capture_device_issued_at" ||
      capture_die 'the target observation is stale or not current'
  fi
  if [ "$capture_reuses_verified_target" = true ]; then
    :
  elif [ "$capture_requires_patch_context" = true ]; then
    if ! capture_run_as_call "$capture_package" cat "$capture_patch_context" >"$capture_grant_temp_dir/patch.json"; then
      capture_die 'the current app-owned successful patch-information context is absent or unreadable'
    fi
    chmod 600 "$capture_grant_temp_dir/patch.json"
    if [ "$capture_requires_activation_source" = true ]; then
      capture_require_command dart
      capture_activation_source_hash=$(sed -n '1p' "$capture_activation_source_hash_file")
      printf '%s\n' "$capture_activation_source_hash" | grep -Eq '^[0-9a-f]{64}$' ||
        capture_die 'the private Gen1 FRAM capture hash is invalid'
      [ "$(capture_sha256_file "$capture_activation_source")" = "$capture_activation_source_hash" ] ||
        capture_die 'the private Gen1 FRAM capture changed after collection'
      if ! (CDPATH='' cd "$capture_libre_package" &&
        dart run tool/validate_gen1_fram_capture.dart "$capture_activation_source") \
        >"$capture_grant_temp_dir/source-validation.json" \
        2>"$capture_grant_temp_dir/source-validation.stderr"; then
        chmod 600 "$capture_grant_temp_dir/source-validation.stderr"
        capture_die 'the private Gen1 activation source failed offline validation'
      fi
      chmod 600 "$capture_grant_temp_dir/source-validation.json"
      rm -f "$capture_grant_temp_dir/source-validation.stderr"
      [ "$(capture_sha256_file "$capture_activation_source")" = "$capture_activation_source_hash" ] ||
        capture_die 'the private Gen1 FRAM capture changed during offline validation'
      capture_device_issued_at=$(capture_read_value shell date '+%s%3N')
      printf '%s\n' "$capture_device_issued_at" | grep -Eq '^[0-9]{13}$' ||
        capture_die 'the phone clock became unavailable after offline validation'
      capture_validate_target_observation \
        "$capture_grant_temp_dir/target.json" "$capture_selection" "$capture_device_issued_at" ||
        capture_die 'the target observation became stale during offline validation'
      if ! capture_build_target_unverified_gen1_activation_grant \
        "$capture_grant_temp_dir/context.json" \
        "$capture_grant_temp_dir/target.json" \
        "$capture_grant_temp_dir/patch.json" \
        "$capture_activation_source" \
        "$capture_activation_source_hash" \
        "$capture_grant_temp_dir/source-validation.json" \
        "$capture_selection" \
        "$capture_grant_temp_dir/grant.json" \
        "${capture_session##*/}" \
        "$capture_device_issued_at" \
        2>"$capture_grant_temp_dir/grant-validation.stderr"; then
        chmod 600 "$capture_grant_temp_dir/grant-validation.stderr"
        capture_die 'the Gen1 activation source is invalid or not bound to this target/build/session'
      fi
    else
      if ! capture_build_target_unverified_gen1_fram_grant \
        "$capture_grant_temp_dir/context.json" \
        "$capture_grant_temp_dir/target.json" \
        "$capture_grant_temp_dir/patch.json" \
        "$capture_selection" \
        "$capture_grant_temp_dir/grant.json" \
        "${capture_session##*/}" \
        "$capture_device_issued_at" \
        2>"$capture_grant_temp_dir/grant-validation.stderr"; then
        chmod 600 "$capture_grant_temp_dir/grant-validation.stderr"
        capture_die 'the Gen1 patch-information context is invalid, stale, or not bound to this target/build/session'
      fi
    fi
  else
    if ! capture_build_target_unverified_grant \
      "$capture_grant_temp_dir/context.json" \
      "$capture_grant_temp_dir/target.json" \
      "$capture_selection" \
      "$capture_grant_temp_dir/grant.json" \
      "${capture_session##*/}" \
      "$capture_device_issued_at" \
      2>"$capture_grant_temp_dir/grant-validation.stderr"; then
      chmod 600 "$capture_grant_temp_dir/grant-validation.stderr"
      capture_die 'the app-owned NFC grant context is invalid'
    fi
  fi
  rm -f "$capture_grant_temp_dir/grant-validation.stderr"
  capture_grant_pending=$capture_grant_path.pending
  if ! capture_run_as_upload "$capture_package" tee "$capture_grant_pending" \
    <"$capture_grant_temp_dir/grant.json" >/dev/null; then
    capture_die "could not stage the session/build-bound $capture_grant_kind grant"
  fi
  capture_run_as_call "$capture_package" chmod 600 "$capture_grant_pending" ||
    capture_die "could not protect the staged $capture_grant_kind grant"
  capture_run_as_call "$capture_package" sync "$capture_grant_pending" ||
    capture_die "could not durably flush the staged $capture_grant_kind grant"
  capture_run_as_call "$capture_package" mv "$capture_grant_pending" "$capture_grant_path" ||
    capture_die "could not atomically publish the $capture_grant_kind grant"
  capture_run_as_call "$capture_package" sync files/protocol-captures ||
    capture_die 'could not durably flush the app-private grant directory'
  capture_record_marker "session=${capture_session##*/} event=${capture_arm_marker}-armed risk=R3"
  capture_release_arm_rf_lease ||
    capture_die 'could not release the app-private NFC RF lease after durable grant publication'
  capture_arm_cleanup_device=false
  capture_cleanup_arm
  capture_grant_temp_dir=
  trap - EXIT HUP INT TERM
  if [ "$capture_grant_kind" = target-unverified-gen1-fram-read ]; then
    capture_grant_ttl_seconds=300
  else
    capture_grant_ttl_seconds=90
  fi
  printf 'armed: one session/build/target-bound %s grant (expires in %s seconds)\n' \
    "$capture_grant_kind" "$capture_grant_ttl_seconds"
}

capture_validate_gen1_fram_capture() {
  capture_artifact_file=$1
  capture_target_file=$2
  capture_patch_file=$3
  capture_selection_file=$4
  capture_session_id=$5
  capture_phone_now=$6
  capture_binding_mode=$7
  ruby -rjson -rtime -rdigest -e '
    artifact = JSON.parse(File.read(ARGV.fetch(0)))
    target = JSON.parse(File.read(ARGV.fetch(1)))
    patch = JSON.parse(File.read(ARGV.fetch(2)))
    selected = File.readlines(ARGV.fetch(3), chomp: true).to_h { |line| line.split("=", 2) }
    session_id = ARGV.fetch(4)
    now_text = ARGV.fetch(5)
    binding_mode = ARGV.fetch(6)
    host_artifact_keys = %w[schemaVersion nativeCaptureSessionId processSessionId captureSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix patchInfoSha256 model securityGeneration algorithmOrderUidHex patchInfoHex encryptedFramHex observedAtUtc observedAtMonotonicElapsedNanos].sort
    explicit_artifact_keys = (host_artifact_keys + %w[sourceKind explicitAttemptId]).sort
    target_keys = %w[schemaVersion nativeCaptureSessionId processSessionId targetUidSha256 iso15693ManufacturerPrefix observedAtUtc observedAtMonotonicElapsedNanos].sort
    patch_keys = %w[schemaVersion nativeCaptureSessionId processSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix model generation patchInfoSha256 observedAtUtc observedAtMonotonicElapsedNanos].sort
    parse_utc_ms = lambda do |value|
      next nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\z/)
      (Time.iso8601(value).to_r * 1000).to_i rescue nil
    end
    now_ms = now_text.match?(/\A[0-9]{13}\z/) ? now_text.to_i : nil
    artifact_ms = artifact.is_a?(Hash) ? parse_utc_ms.call(artifact["observedAtUtc"]) : nil
    target_ms = target.is_a?(Hash) ? parse_utc_ms.call(target["observedAtUtc"]) : nil
    patch_ms = patch.is_a?(Hash) ? parse_utc_ms.call(patch["observedAtUtc"]) : nil
    fresh = lambda do |timestamp_ms|
      !now_ms.nil? && !timestamp_ms.nil? && now_ms - timestamp_ms >= -5_000 &&
        now_ms - timestamp_ms <= 120_000
    end
    algorithm_uid = artifact.is_a?(Hash) && artifact["algorithmOrderUidHex"].is_a?(String) &&
      artifact["algorithmOrderUidHex"].match?(/\A[0-9a-f]{16}\z/) ?
      [artifact["algorithmOrderUidHex"]].pack("H*") : nil
    patch_info = artifact.is_a?(Hash) && artifact["patchInfoHex"].is_a?(String) &&
      artifact["patchInfoHex"].match?(/\A[0-9a-f]{12}\z/) ?
      [artifact["patchInfoHex"]].pack("H*") : nil
    target_hash_from_uid = algorithm_uid.nil? ? nil : Digest::SHA256.hexdigest(algorithm_uid)
    manufacturer_prefix_from_uid = algorithm_uid.nil? ? nil :
      algorithm_uid.bytes.values_at(7, 6).pack("C*").unpack1("H*")
    patch_hash_from_payload = patch_info.nil? ? nil : Digest::SHA256.hexdigest(patch_info)
    host_source = artifact.is_a?(Hash) && artifact["schemaVersion"] == 1 &&
      artifact.keys.sort == host_artifact_keys && artifact["captureSessionId"] == session_id
    explicit_source = artifact.is_a?(Hash) && artifact["schemaVersion"] == 2 &&
      artifact.keys.sort == explicit_artifact_keys &&
      artifact["sourceKind"] == "explicitLibre2Lifecycle" &&
      artifact["explicitAttemptId"].is_a?(String) &&
      artifact["explicitAttemptId"].match?(/\A[A-Za-z0-9_-]{8,120}\z/) &&
      ((binding_mode == "source" &&
          (artifact["captureSessionId"].nil? || artifact["captureSessionId"] == session_id)) ||
        (binding_mode == "bound" && artifact["captureSessionId"] == session_id))
    valid = artifact.is_a?(Hash) && (host_source || explicit_source) &&
      target.is_a?(Hash) && target.keys.sort == target_keys &&
      patch.is_a?(Hash) && patch.keys.sort == patch_keys &&
      session_id.match?(/\Asession-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\z/) &&
      target["schemaVersion"] == 1 &&
      target["nativeCaptureSessionId"] == selected["native_session"] &&
      target["processSessionId"] == selected["process_session"] &&
      target["targetUidSha256"].is_a?(String) && target["targetUidSha256"].match?(/\A[0-9a-f]{64}\z/) &&
      target["iso15693ManufacturerPrefix"] == "e007" &&
      target["observedAtMonotonicElapsedNanos"].is_a?(Integer) &&
      target["observedAtMonotonicElapsedNanos"] > 0 && fresh.call(target_ms) &&
      patch["schemaVersion"] == 1 &&
      patch["nativeCaptureSessionId"] == selected["native_session"] &&
      patch["processSessionId"] == selected["process_session"] &&
      patch["versionCode"].is_a?(Integer) && patch["versionCode"].to_s == selected["version_code"] &&
      patch["lastUpdateTime"].is_a?(Integer) && patch["lastUpdateTime"].to_s == selected["last_update_time"] &&
      patch["targetUidSha256"] == target["targetUidSha256"] &&
      patch["iso15693ManufacturerPrefix"] == "e007" &&
      %w[libre2 libre2Plus].include?(patch["model"]) && patch["generation"] == "gen1" &&
      patch["patchInfoSha256"].is_a?(String) && patch["patchInfoSha256"].match?(/\A[0-9a-f]{64}\z/) &&
      patch["observedAtMonotonicElapsedNanos"].is_a?(Integer) &&
      patch["observedAtMonotonicElapsedNanos"] > 0 && fresh.call(patch_ms) &&
      artifact["nativeCaptureSessionId"] == selected["native_session"] &&
      artifact["processSessionId"] == selected["process_session"] &&
      artifact["versionCode"].is_a?(Integer) && artifact["versionCode"].to_s == selected["version_code"] &&
      artifact["lastUpdateTime"].is_a?(Integer) && artifact["lastUpdateTime"].to_s == selected["last_update_time"] &&
      artifact["targetUidSha256"] == target["targetUidSha256"] &&
      artifact["targetUidSha256"] == target_hash_from_uid &&
      artifact["iso15693ManufacturerPrefix"] == "e007" &&
      artifact["iso15693ManufacturerPrefix"] == manufacturer_prefix_from_uid &&
      artifact["patchInfoSha256"] == patch["patchInfoSha256"] &&
      artifact["patchInfoSha256"] == patch_hash_from_payload &&
      artifact["model"] == patch["model"] && artifact["securityGeneration"] == "gen1" &&
      artifact["encryptedFramHex"].is_a?(String) && artifact["encryptedFramHex"].match?(/\A[0-9a-f]{688}\z/) &&
      artifact["observedAtMonotonicElapsedNanos"].is_a?(Integer) &&
      artifact["observedAtMonotonicElapsedNanos"] >= target["observedAtMonotonicElapsedNanos"] &&
      artifact["observedAtMonotonicElapsedNanos"] >= patch["observedAtMonotonicElapsedNanos"] &&
      fresh.call(artifact_ms) && artifact_ms >= target_ms && artifact_ms >= patch_ms
    abort "invalid, stale, or cross-bound Gen1 FRAM capture" unless valid
  ' "$capture_artifact_file" "$capture_target_file" "$capture_patch_file" \
    "$capture_selection_file" "$capture_session_id" "$capture_phone_now" \
    "$capture_binding_mode"
}

capture_collect_gen1_fram_command() {
  capture_session_arg=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || capture_die '--session needs a value'; capture_session_arg=$2; shift 2 ;;
      *) capture_die "unknown collect-gen1-fram-capture option: $1" ;;
    esac
  done
  [ -n "$capture_session_arg" ] || capture_die '--session is required'
  capture_require_session "$capture_session_arg"
  [ "$capture_profile" = libre ] ||
    capture_die 'Libre Gen1 FRAM collection is disabled for this capture profile'
  [ "$capture_package" = com.openglucose.app.debug ] ||
    capture_die 'Libre Gen1 FRAM collection is restricted to com.openglucose.app.debug'
  capture_require_matching_device
  capture_require_active_logcat
  capture_verify_app_ready_impl
  capture_arm_cleanup_device=false
  trap capture_cleanup_collect EXIT
  trap 'exit 130' HUP INT TERM
  capture_acquire_arm_rf_lease
  capture_phone_now=$(capture_read_value shell date '+%s%3N')
  printf '%s\n' "$capture_phone_now" | grep -Eq '^[0-9]{13}$' ||
    capture_die 'the phone did not provide a strict 13-digit epoch-millisecond clock; refusing to collect'

  capture_private_dir=$capture_session/restricted
  if [ -e "$capture_private_dir" ]; then
    [ -d "$capture_private_dir" ] && [ ! -L "$capture_private_dir" ] ||
      capture_die 'the restricted artifact path is not a safe directory'
  else
    mkdir "$capture_private_dir"
  fi
  chmod 700 "$capture_private_dir"
  capture_collect_destination=$capture_private_dir/nfc-gen1-fram-capture.json
  capture_collect_hash_destination=$capture_private_dir/nfc-gen1-fram-capture.sha256
  [ ! -e "$capture_collect_destination" ] && [ ! -e "$capture_collect_destination.pending" ] &&
    [ ! -e "$capture_collect_hash_destination" ] && [ ! -e "$capture_collect_hash_destination.pending" ] ||
    capture_die 'a Gen1 FRAM capture is already collected or pending in this session'

  capture_collect_temp_dir=$(mktemp -d "$capture_session/.fram-collect-XXXXXX")
  chmod 700 "$capture_collect_temp_dir"
  capture_collect_cleanup_destination=true
  capture_source=files/protocol-captures/nfc-gen1-fram-capture.json
  capture_rebind_workspace=files/protocol-captures/nfc-gen1-fram-rebind-$capture_lease_token
  capture_rebind_workspace_marker=$capture_rebind_workspace/owner-$capture_lease_token
  capture_rebind_backup_path=$capture_rebind_workspace/original
  capture_rebind_pending_path=$capture_rebind_workspace/source.pending
  capture_rebind_workspace_owned=false
  capture_rebind_promotion_started=false
  capture_rebind_promoted=false
  capture_rebind_committed=false
  capture_target_context=files/protocol-captures/nfc-target-context.json
  capture_patch_context=files/protocol-captures/nfc-patch-info-context.json
  if ! capture_run_as_call "$capture_package" cat "$capture_source" \
    >"$capture_collect_temp_dir/artifact.json" 2>"$capture_collect_temp_dir/artifact.stderr"; then
    capture_die 'the app-owned Gen1 FRAM capture is absent or unreadable'
  fi
  if ! capture_run_as_call "$capture_package" cat "$capture_target_context" \
    >"$capture_collect_temp_dir/target.json" 2>>"$capture_collect_temp_dir/artifact.stderr"; then
    capture_die 'the current app-owned NFC target context is absent or unreadable'
  fi
  if ! capture_run_as_call "$capture_package" cat "$capture_patch_context" \
    >"$capture_collect_temp_dir/patch.json" 2>>"$capture_collect_temp_dir/artifact.stderr"; then
    capture_die 'the current app-owned patch-information context is absent or unreadable'
  fi
  chmod 600 "$capture_collect_temp_dir/artifact.json" \
    "$capture_collect_temp_dir/artifact.stderr" \
    "$capture_collect_temp_dir/target.json" "$capture_collect_temp_dir/patch.json"
  rm -f "$capture_collect_temp_dir/artifact.stderr"
  if ! capture_validate_gen1_fram_capture \
    "$capture_collect_temp_dir/artifact.json" \
    "$capture_collect_temp_dir/target.json" \
    "$capture_collect_temp_dir/patch.json" \
    "$capture_selection" \
    "${capture_session##*/}" \
    "$capture_phone_now" \
    source \
    2>"$capture_collect_temp_dir/validation.stderr"; then
    chmod 600 "$capture_collect_temp_dir/validation.stderr"
    capture_die 'the Gen1 FRAM capture is invalid, stale, or not bound to this target/build/session'
  fi
  rm -f "$capture_collect_temp_dir/validation.stderr"
  if ruby -rjson -e '
    value = JSON.parse(File.read(ARGV.fetch(0)))
    exit(value["schemaVersion"] == 2 && value["captureSessionId"].nil? ? 0 : 1)
  ' "$capture_collect_temp_dir/artifact.json"; then
    ruby -rjson -e '
      source, destination, session_id = ARGV
      value = JSON.parse(File.read(source))
      valid = value.is_a?(Hash) && value["schemaVersion"] == 2 &&
        value["captureSessionId"].nil? &&
        value["sourceKind"] == "explicitLibre2Lifecycle" &&
        value["explicitAttemptId"].is_a?(String) &&
        value["explicitAttemptId"].match?(/\A[A-Za-z0-9_-]{8,120}\z/) &&
        session_id.match?(/\Asession-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+\z/)
      abort "explicit FRAM source cannot be rebound" unless valid
      value["captureSessionId"] = session_id
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(value))
        file.write("\n")
        file.flush
        file.fsync
      end
    ' "$capture_collect_temp_dir/artifact.json" \
      "$capture_collect_temp_dir/rebound.json" "${capture_session##*/}"
    cp "$capture_collect_temp_dir/artifact.json" \
      "$capture_collect_temp_dir/rebind-original.json"
    chmod 600 "$capture_collect_temp_dir/rebind-original.json"
    capture_run_as_call "$capture_package" mkdir "$capture_rebind_workspace" ||
      capture_die 'could not exclusively create the app-owned Gen1 FRAM rebind workspace'
    capture_run_as_call "$capture_package" chmod 700 "$capture_rebind_workspace" ||
      capture_die 'could not protect the app-owned Gen1 FRAM rebind workspace'
    capture_run_as_call "$capture_package" touch "$capture_rebind_workspace_marker" ||
      capture_die 'could not create the app-owned Gen1 FRAM rebind ownership marker'
    capture_run_as_call "$capture_package" chmod 600 "$capture_rebind_workspace_marker" ||
      capture_die 'could not protect the app-owned Gen1 FRAM rebind ownership marker'
    capture_run_as_call "$capture_package" sync "$capture_rebind_workspace_marker" ||
      capture_die 'could not durably flush the app-owned Gen1 FRAM rebind ownership marker'
    capture_run_as_call "$capture_package" sync "$capture_rebind_workspace" ||
      capture_die 'could not durably flush the app-owned Gen1 FRAM rebind workspace'
    capture_rebind_entries=$(capture_run_as_call "$capture_package" ls -1A \
      "$capture_rebind_workspace") ||
      capture_die 'could not verify the app-owned Gen1 FRAM rebind workspace'
    [ "$capture_rebind_entries" = "${capture_rebind_workspace_marker##*/}" ] ||
      capture_die 'the app-owned Gen1 FRAM rebind workspace has an unexpected owner'
    capture_rebind_workspace_owned=true
    capture_run_as_call "$capture_package" cp \
      "$capture_source" "$capture_rebind_backup_path" ||
      capture_die 'could not preserve the original app-owned Gen1 FRAM source'
    capture_run_as_call "$capture_package" chmod 600 \
      "$capture_rebind_backup_path" ||
      capture_die 'could not protect the app-owned Gen1 FRAM rollback source'
    capture_run_as_call "$capture_package" sync \
      "$capture_rebind_backup_path" ||
      capture_die 'could not durably flush the app-owned Gen1 FRAM rollback source'
    capture_run_as_call "$capture_package" sync files/protocol-captures ||
      capture_die 'could not durably flush the app-owned Gen1 FRAM rollback directory'
    capture_run_as_call "$capture_package" cat "$capture_rebind_backup_path" \
      >"$capture_collect_temp_dir/rebind-backup-readback.json" ||
      capture_die 'could not verify the app-owned Gen1 FRAM rollback source'
    cmp -s "$capture_collect_temp_dir/rebind-original.json" \
      "$capture_collect_temp_dir/rebind-backup-readback.json" ||
      capture_die 'the app-owned Gen1 FRAM rollback source changed during staging'
    capture_run_as_upload "$capture_package" tee "$capture_rebind_pending_path" \
      <"$capture_collect_temp_dir/rebound.json" >/dev/null ||
      capture_die 'could not stage the app-owned Gen1 FRAM rebind'
    capture_run_as_call "$capture_package" chmod 600 "$capture_rebind_pending_path" ||
      capture_die 'could not protect the app-owned Gen1 FRAM rebind'
    capture_run_as_call "$capture_package" sync "$capture_rebind_pending_path" ||
      capture_die 'could not durably flush the app-owned Gen1 FRAM rebind'
    capture_run_as_call "$capture_package" cat "$capture_rebind_pending_path" \
      >"$capture_collect_temp_dir/rebind-pending-readback.json" ||
      capture_die 'could not read back the staged app-owned Gen1 FRAM rebind'
    cmp -s "$capture_collect_temp_dir/rebound.json" \
      "$capture_collect_temp_dir/rebind-pending-readback.json" ||
      capture_die 'the staged app-owned Gen1 FRAM rebind changed during upload'
    if ! capture_validate_gen1_fram_capture \
      "$capture_collect_temp_dir/rebind-pending-readback.json" \
      "$capture_collect_temp_dir/target.json" \
      "$capture_collect_temp_dir/patch.json" \
      "$capture_selection" \
      "${capture_session##*/}" \
      "$capture_phone_now" \
      bound \
      2>"$capture_collect_temp_dir/validation.stderr"; then
      chmod 600 "$capture_collect_temp_dir/validation.stderr"
      capture_die 'the staged app-owned Gen1 FRAM rebind failed exact validation'
    fi
    rm -f "$capture_collect_temp_dir/validation.stderr"
    # An ADB failure can be ambiguous after the device performs the rename.
    # Cleanup must restore the exact backup from this point until commit.
    capture_rebind_promotion_started=true
    capture_run_as_call "$capture_package" mv "$capture_rebind_pending_path" "$capture_source" ||
      capture_die 'could not atomically publish the app-owned Gen1 FRAM rebind'
    capture_rebind_promoted=true
    capture_run_as_call "$capture_package" sync files/protocol-captures ||
      capture_die 'could not durably flush the app-owned Gen1 FRAM rebind directory'
    capture_run_as_call "$capture_package" cat "$capture_source" \
      >"$capture_collect_temp_dir/rebound-readback.json" ||
      capture_die 'could not verify the rebound app-owned Gen1 FRAM source'
    cmp -s "$capture_collect_temp_dir/rebound.json" \
      "$capture_collect_temp_dir/rebound-readback.json" ||
      capture_die 'the rebound app-owned Gen1 FRAM source changed during publication'
    mv "$capture_collect_temp_dir/rebound-readback.json" \
      "$capture_collect_temp_dir/artifact.json"
  fi
  if ! capture_validate_gen1_fram_capture \
    "$capture_collect_temp_dir/artifact.json" \
    "$capture_collect_temp_dir/target.json" \
    "$capture_collect_temp_dir/patch.json" \
    "$capture_selection" \
    "${capture_session##*/}" \
    "$capture_phone_now" \
    bound \
    2>"$capture_collect_temp_dir/validation.stderr"; then
    chmod 600 "$capture_collect_temp_dir/validation.stderr"
    capture_die 'the rebound Gen1 FRAM capture is invalid or cross-bound'
  fi
  rm -f "$capture_collect_temp_dir/validation.stderr"
  if [ "$capture_rebind_promoted" = true ]; then
    # Final readback and schema validation completed while the exact host lease
    # was held. From this point the rebound source is the committed source.
    capture_rebind_committed=true
    capture_run_as_call "$capture_package" rm -f \
      "$capture_rebind_backup_path" "$capture_rebind_workspace_marker" ||
      capture_die 'could not remove the committed app-owned FRAM rollback source'
    capture_run_as_call "$capture_package" rmdir "$capture_rebind_workspace" ||
      capture_die 'could not remove the committed app-owned FRAM rebind workspace'
    capture_run_as_call "$capture_package" sync files/protocol-captures ||
      capture_die 'could not durably flush committed app-owned FRAM cleanup'
    capture_rebind_workspace_owned=false
  fi
  mv "$capture_collect_temp_dir/artifact.json" "$capture_collect_destination.pending"
  chmod 600 "$capture_collect_destination.pending"
  capture_sha256_file "$capture_collect_destination.pending" \
    >"$capture_collect_hash_destination.pending"
  chmod 600 "$capture_collect_hash_destination.pending"
  ruby -e '
    pending_artifact, final_artifact, pending_hash, final_hash, directory = ARGV
    [pending_artifact, pending_hash].each do |path|
      File.open(path, File::RDONLY) { |file| file.fsync }
    end
    File.rename(pending_artifact, final_artifact)
    File.rename(pending_hash, final_hash)
    File.open(directory, File::RDONLY) { |dir| dir.fsync }
  ' "$capture_collect_destination.pending" "$capture_collect_destination" \
    "$capture_collect_hash_destination.pending" "$capture_collect_hash_destination" \
    "$capture_private_dir"
  capture_artifact_hash=$(sed -n '1p' "$capture_collect_hash_destination")
  printf '%s\n' "$capture_artifact_hash" | grep -Eq '^[0-9a-f]{64}$' ||
    capture_die 'the collected artifact hash is invalid'
  capture_release_arm_rf_lease ||
    capture_die 'could not release the exact app-private NFC RF lease after collection'
  capture_record_marker "session=${capture_session##*/} event=gen1-fram-capture-collected"
  capture_collect_cleanup_destination=false
  capture_cleanup_collect
  capture_collect_temp_dir=
  trap - EXIT HUP INT TERM
  printf '%s\n' 'COLLECTED: one current, schema-bound Gen1 FRAM capture is stored privately.'
  printf 'artifact_sha256=%s\n' "$capture_artifact_hash"
}

capture_bugreport_impl() {
  capture_report_index=1
  while :; do
    capture_report=$(printf '%s/reports/bugreport-%04d.zip' "$capture_session" "$capture_report_index")
    [ -e "$capture_report" ] || [ -e "$capture_report.pending" ] || break
    capture_report_index=$((capture_report_index + 1))
    [ "$capture_report_index" -le 9999 ] || capture_die 'bugreport index is exhausted'
  done
  capture_record_marker "session=${capture_session##*/} event=bugreport-requested" || :
  if capture_adb_call bugreport "$capture_report.pending" >"$capture_report.progress.txt" 2>&1; then
    if [ -f "$capture_report.pending" ]; then
      mv "$capture_report.pending" "$capture_report"
    elif [ -f "$capture_report.pending.zip" ]; then
      mv "$capture_report.pending.zip" "$capture_report"
    else
      capture_die 'ADB reported success but did not create the requested bugreport'
    fi
    chmod 600 "$capture_report" "$capture_report.progress.txt"
    capture_write_hashes "$capture_session/reports"
    if [ "$(sed -n '1p' "$capture_session/state")" = stopped ]; then
      capture_write_hashes "$capture_session"
    fi
    printf '%s\n' "$capture_report"
    return 0
  fi
  chmod 600 "$capture_report.progress.txt"
  capture_die 'ADB bugreport failed; inspect its progress file'
}

capture_bugreport_command() {
  capture_session_arg=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || capture_die '--session needs a value'; capture_session_arg=$2; shift 2 ;;
      *) capture_die "unknown bugreport option: $1" ;;
    esac
  done
  [ -n "$capture_session_arg" ] || capture_die '--session is required'
  capture_require_session "$capture_session_arg"
  capture_require_matching_device
  capture_bugreport_impl
}

capture_stop_command() {
  capture_session_arg=
  capture_label=phase-99-final
  capture_with_bugreport=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || capture_die '--session needs a value'; capture_session_arg=$2; shift 2 ;;
      --label) [ "$#" -ge 2 ] || capture_die '--label needs a value'; capture_label=$2; shift 2 ;;
      --bugreport) capture_with_bugreport=true; shift ;;
      *) capture_die "unknown stop option: $1" ;;
    esac
  done
  [ -n "$capture_session_arg" ] || capture_die '--session is required'
  capture_require_session "$capture_session_arg"
  capture_require_matching_device
  capture_validate_label "$capture_label"
  capture_stop_failures=0
  if [ "$capture_package" = com.openglucose.app.debug ]; then
    capture_run_as_call "$capture_package" mkdir -p files/protocol-captures ||
      capture_die 'could not create the app-private protocol-captures directory'
    capture_run_as_call "$capture_package" chmod 700 files/protocol-captures ||
      capture_die 'could not protect the app-private protocol-captures directory'
    capture_arm_cleanup_device=false
    trap capture_cleanup_arm EXIT
    trap 'exit 130' HUP INT TERM
    capture_acquire_arm_rf_lease
    capture_record_marker "session=${capture_session##*/} event=target-unverified-nfc-auto-disarm-requested" || :
    if ! capture_remove_target_unverified_grants; then
      capture_stop_failures=$((capture_stop_failures + 1))
    fi
  fi
  if ! (capture_snapshot_impl "$capture_label" >/dev/null); then
    capture_stop_failures=$((capture_stop_failures + 1))
  fi
  capture_require_active_logcat
  capture_stop_status_before=$capture_session/stop-status-before.json
  if ! capture_run_as_text_artifact "$capture_stop_status_before" "$capture_package" cat files/protocol-captures/capture-status.json; then
    capture_stop_failures=$((capture_stop_failures + 1))
  fi
  capture_record_marker "session=${capture_session##*/} event=stop" || :
  if [ "$capture_package" = com.openglucose.app.debug ]; then
    capture_require_matching_android_user
    capture_adb_call shell -n am force-stop --user "$capture_expected_android_user_id" "$capture_package" ||
      capture_stop_failures=$((capture_stop_failures + 1))
    capture_wait=0
    while [ -n "$(capture_pidof "$capture_package")" ] && [ "$capture_wait" -lt 30 ]; do
      sleep 0.1
      capture_wait=$((capture_wait + 1))
    done
    [ -z "$(capture_pidof "$capture_package")" ] || capture_stop_failures=$((capture_stop_failures + 1))
    capture_stop_status_after_one=$capture_session/stop-status-after-1.json
    capture_stop_status_after_two=$capture_session/stop-status-after-2.json
    capture_after_one_present=false
    capture_run_as_text_artifact "$capture_stop_status_after_one" "$capture_package" cat files/protocol-captures/capture-status.json &&
      capture_after_one_present=true
    sleep 3
    capture_after_two_present=false
    capture_run_as_text_artifact "$capture_stop_status_after_two" "$capture_package" cat files/protocol-captures/capture-status.json &&
      capture_after_two_present=true
    if [ "$capture_after_one_present" = true ] && [ "$capture_after_two_present" = true ]; then
      cmp -s "$capture_stop_status_after_one" "$capture_stop_status_after_two" ||
        capture_stop_failures=$((capture_stop_failures + 1))
      printf '%s\n' stale-unchanged >"$capture_session/stop-status-result.txt"
    elif [ "$capture_after_one_present" = false ] && [ "$capture_after_two_present" = false ]; then
      printf '%s\n' absent-after-stop >"$capture_session/stop-status-result.txt"
    else
      printf '%s\n' inconsistent-after-stop >"$capture_session/stop-status-result.txt"
      capture_stop_failures=$((capture_stop_failures + 1))
    fi
    chmod 600 "$capture_session/stop-status-result.txt"
  fi
  capture_stop_pid_safely "$capture_pid" "$capture_expected"
  printf '%s\n' stopped >"$capture_session/state"
  if [ "$capture_with_bugreport" = true ]; then
    if ! (capture_bugreport_impl >/dev/null); then
      capture_stop_failures=$((capture_stop_failures + 1))
    fi
  fi
  capture_write_hashes "$capture_session"
  if [ "$capture_package" = com.openglucose.app.debug ]; then
    if capture_release_arm_rf_lease; then
      trap - EXIT HUP INT TERM
    else
      capture_stop_failures=$((capture_stop_failures + 1))
    fi
  fi
  printf '%s\n' "$capture_session"
  [ "$capture_stop_failures" -eq 0 ] ||
    capture_die 'session logcat stopped safely, but one or more final artifacts are incomplete'
}

[ "$#" -gt 0 ] || { capture_usage; exit 1; }
capture_command=$1
shift
case "$capture_command" in
  doctor) capture_doctor "$@" ;;
  start) capture_start "$@" ;;
  verify-app-ready) capture_verify_app_ready_command "$@" ;;
  verify-target-observation) capture_verify_target_observation_command "$@" ;;
  snapshot) capture_snapshot_command "$@" ;;
  arm-target-unverified-nfc-probe) capture_nfc_arm_command arm-target-unverified-nfc-probe "$@" ;;
  arm-target-unverified-nfc-probe-from-verified-target) capture_nfc_arm_command arm-target-unverified-nfc-probe-from-verified-target "$@" ;;
  disarm-target-unverified-nfc-probe) capture_nfc_arm_command disarm-target-unverified-nfc-probe "$@" ;;
  arm-target-unverified-gen1-fram-read) capture_nfc_arm_command arm-target-unverified-gen1-fram-read "$@" ;;
  disarm-target-unverified-gen1-fram-read) capture_nfc_arm_command disarm-target-unverified-gen1-fram-read "$@" ;;
  arm-target-unverified-gen1-activation) capture_nfc_arm_command arm-target-unverified-gen1-activation "$@" ;;
  disarm-target-unverified-gen1-activation) capture_nfc_arm_command disarm-target-unverified-gen1-activation "$@" ;;
  collect-gen1-fram-capture) capture_collect_gen1_fram_command "$@" ;;
  bugreport) capture_bugreport_command "$@" ;;
  stop) capture_stop_command "$@" ;;
  help | --help | -h) capture_usage ;;
  *) capture_die "unknown command: $capture_command" ;;
esac
