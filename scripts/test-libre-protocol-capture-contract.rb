#!/usr/bin/env ruby
require "digest"; require "fileutils"; require "json"; require "open3"; require "tmpdir"
ROOT = File.expand_path("..", __dir__); HARNESS = File.join(__dir__, "libre-protocol-capture.sh")
YUWELL_HARNESS = File.join(__dir__, "yuwell-anytime-passive-capture.sh")
TARGET_HASH = "220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1"
PATCH_HASH = "20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91"
ALGORITHM_UID_HEX = "01020304050607e0"
PATCH_INFO_HEX = "9d0830000000"
def assert(value, message)
  raise "assertion failed: #{message}" unless value
end
def run(env, *command)
  Open3.capture3(env, *command)
end
Dir.mktmpdir("libre-contract") do |tmp|
  bin, output, state = %w[bin private state].map { |n| File.join(tmp, n) }
  audit, grant, fram_grant, activation_grant, rf_lease = File.join(tmp, "audit"), File.join(tmp, "grant"), File.join(tmp, "fram-grant"), File.join(tmp, "activation-grant"), File.join(tmp, "rf-lease")
  FileUtils.mkdir_p([bin, state], mode: 0o700); File.write(File.join(state, "running"), "1\n"); File.write(File.join(state, "count"), "0\n")
  adb = File.join(bin, "adb")
  File.write(adb, <<~'SH')
    #!/bin/sh
    set -eu
    printf '%s\n' "$*" >>"$FAKE_AUDIT"; running=$(cat "$FAKE_STATE/running")
    status_json() {
      n=$(cat "$FAKE_STATE/count"); if [ "$running" = 1 ]; then n=$((n+1)); printf '%s\n' "$n" >"$FAKE_STATE/count"; fi
      scanner=${FAKE_APP_CAPTURE_STATE:-running}; rf=true; [ "$scanner" = running ] || rf=false
      timestamp=$(printf '2030-01-01T00:%02d:%02dZ' "$((n/60))" "$((n%60))")
      services='["0000fde3-0000-1000-8000-00805f9b34fb"]'
      if [ "${OPENGLUCOSE_CAPTURE_PROFILE:-libre}" = yuwell_anytime_passive ]; then
        services='[]'
      elif [ "${OPENGLUCOSE_CAPTURE_LIVE_AIDEX:-false}" = true ]; then
        services='["0000fde3-0000-1000-8000-00805f9b34fb","0000181f-0000-1000-8000-00805f9b34fb"]'
      fi
      [ -z "${FAKE_APP_CAPTURE_SERVICES:-}" ] || services=$FAKE_APP_CAPTURE_SERVICES
      printf '{"processSessionId":"processSession01","bleTraceSessionId":"bleSession01","bleTraceFileName":"ble-bleSession01-00.jsonl","scannerState":"%s","scannerServiceUuids":%s,"sinkState":"healthy","lastCommittedBleSequence":%s,"lastCommittedBleRecordedAtUtc":"%s","capacityReached":false,"sinkErrorCode":null,"heartbeatAtUtc":"%s","heartbeatMonotonicMicroseconds":%s,"stopping":false,"schemaVersion":2,"nativeCaptureSessionId":"nativeSession01","processId":4242,"versionCode":123,"lastUpdateTime":1893456000000,"nativeCaptureWritable":true,"nfcTraceFileName":"nfc-nativeSession01-0123456789abcdef0123456789abcdef.jsonl","activityResumed":true,"rfPointOfUseEligible":%s,"statusCommittedAtUtc":"%s","statusCommittedAtElapsedRealtimeNanos":%s}\n' "$scanner" "$services" "$((100+n))" "$timestamp" "$timestamp" "$((1000000+n))" "$rf" "$timestamp" "$((1000000000+n*3000000000))"
    }
    case "${1:-}" in
      devices) printf 'List of devices attached\nFAKE_DEVICE\tdevice\n';; get-state) printf 'device\n';;
      logcat) trap 'exit 0' TERM INT; while :; do /bin/sleep 1 & wait $! || :; done;; bugreport) printf x >"$2";;
      shell)
        shift
        fake_shell_no_stdin=false
        if [ "${1:-}" = -n ]; then fake_shell_no_stdin=true; shift; fi
        if [ "$fake_shell_no_stdin" != true ] && [ "$*" = 'am get-current-user' ]; then
          # Real adb shell consumes its stdin unless -n is present. This makes
          # redirected binary uploads fail if a preflight forgets -n.
          cat >/dev/null
        fi
        last_arg=; for fake_arg in "$@"; do last_arg=$fake_arg; done; case "$*" in
        'am get-current-user') printf '%s\n' "${FAKE_ANDROID_USER_ID:-11}";;
        'settings get secure bluetooth_hci_log') printf '1\n';;
        'settings get global bluetooth_btsnooplogmode'|'getprop persist.bluetooth.btsnooplogmode'|'getprop persist.bluetooth.btsnoopdefaultmode') printf 'full\n';;
        'date +%s%3N') n=$(cat "$FAKE_STATE/count"); printf '%s000\n' "$((1893456000+n))";; 'date +%z') printf '+0000\n';;
        '-T pidof com.openglucose.app.debug'|'pidof com.openglucose.app.debug')
          if [ "${FAKE_PIDOF_FAILURE:-0}" = 1 ]; then printf 'synthetic process-query failure\n' >&2; exit 1; fi
          [ "$running" = 1 ] && printf '4242\n';;
        'am force-stop --user 11 com.openglucose.app.debug') printf '0\n' >"$FAKE_STATE/running";;
        'dumpsys package com.openglucose.app.debug') printf 'versionCode=123 minSdk=26\nlastUpdateTime=2030-01-01 00:00:00\n';;
        dumpsys*|log*) printf 'ok\n';;
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures'|\
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/target-unverified-nfc-grant.json.pending'|\
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending'|\
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/target-unverified-gen1-activation-grant.json.pending'|\
        '-T run-as com.openglucose.app.debug --user 11 mkdir -p files/protocol-captures'|\
        '-T run-as com.openglucose.app.debug --user 11 chmod 700 files/protocol-captures') :;;
        '-T run-as com.openglucose.app.debug --user 11 mkdir files/protocol-captures/nfc-rf-transaction.lease')
          [ "${FAKE_RF_LEASE_BUSY:-0}" != 1 ] && [ ! -e "$FAKE_RF_LEASE" ] || exit 1
          mkdir "$FAKE_RF_LEASE";;
        '-T run-as com.openglucose.app.debug --user 11 touch files/protocol-captures/nfc-rf-transaction.lease/owner-host_'*)
          touch "$FAKE_RF_LEASE/${last_arg##*/}";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 700 files/protocol-captures/nfc-rf-transaction.lease'|\
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/nfc-rf-transaction.lease') :;;
        '-T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/nfc-rf-transaction.lease/owner-host_'*)
          [ "${FAKE_RF_OWNER_CHMOD_FAILURE:-0}" != 1 ] || exit 1
          chmod 600 "$FAKE_RF_LEASE/${last_arg##*/}";;
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/nfc-rf-transaction.lease/owner-host_'*) :;;
        '-T run-as com.openglucose.app.debug --user 11 ls -1A files/protocol-captures/nfc-rf-transaction.lease')
          if [ "${FAKE_RF_UNKNOWN_EXTRA:-0}" = 1 ]; then
            touch "$FAKE_RF_LEASE/owner-native-unknown0001"
          fi
          ls -1A "$FAKE_RF_LEASE";;
        '-T run-as com.openglucose.app.debug --user 11 test -f files/protocol-captures/nfc-rf-transaction.lease/owner-host_'*)
          test -f "$FAKE_RF_LEASE/${last_arg##*/}";;
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/nfc-rf-transaction.lease/owner-host_'*)
          rm -f "$FAKE_RF_LEASE/${last_arg##*/}";;
        '-T run-as com.openglucose.app.debug --user 11 rmdir files/protocol-captures/nfc-rf-transaction.lease')
          rmdir "$FAKE_RF_LEASE";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/target-unverified-nfc-grant.json.pending') chmod 600 "$FAKE_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending') chmod 600 "$FAKE_FRAM_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/target-unverified-gen1-activation-grant.json.pending') chmod 600 "$FAKE_ACTIVATION_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 mv files/protocol-captures/target-unverified-nfc-grant.json.pending files/protocol-captures/target-unverified-nfc-grant.json')
          [ "${FAKE_PATCH_MV_FAILURE:-0}" != 1 ] || exit 1;;
        '-T run-as com.openglucose.app.debug --user 11 mv files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending files/protocol-captures/target-unverified-gen1-fram-read-grant.json')
          [ "${FAKE_FRAM_MV_FAILURE:-0}" != 1 ] || exit 1;;
        '-T run-as com.openglucose.app.debug --user 11 mv files/protocol-captures/target-unverified-gen1-activation-grant.json.pending files/protocol-captures/target-unverified-gen1-activation-grant.json')
          [ "${FAKE_ACTIVATION_MV_FAILURE:-0}" != 1 ] || exit 1;;
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-nfc-grant.json'|\
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-nfc-grant.json.pending') rm -f "$FAKE_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-fram-read-grant.json'|\
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending') rm -f "$FAKE_FRAM_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-activation-grant.json'|\
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-activation-grant.json.pending') rm -f "$FAKE_ACTIVATION_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 test ! -e files/protocol-captures/nfc-gen1-activation-journal.json')
          [ "${FAKE_ACTIVATION_JOURNAL_PRESENT:-0}" != 1 ];;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/capture-status.json')
          [ "${FAKE_STATUS_ABSENT_WHEN_STOPPED:-0}" != 1 ] || [ "$running" = 1 ] || exit 1
          status_json;;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/nfc-grant-context.json') printf '{"schemaVersion":1,"nonce":"0123456789abcdef0123456789abcdef","nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","versionCode":123,"lastUpdateTime":1893456000000,"expectedReferenceIso15693ManufacturerPrefix":"e007"}\n';;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/nfc-target-context.json')
          case "${FAKE_TARGET_CONTEXT_STATE:-valid}" in
            valid) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","observedAtUtc":"2030-01-01T00:00:00Z","observedAtMonotonicElapsedNanos":999999999}\n';;
            fram) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","observedAtUtc":"2030-01-01T00:00:02Z","observedAtMonotonicElapsedNanos":3000000000}\n';;
            stale) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","observedAtUtc":"2029-12-31T23:50:00Z","observedAtMonotonicElapsedNanos":999999999}\n';;
            missing) printf '%s\n' 'cat: app-private context is unavailable' >&2; exit 1;;
            malformed) printf '%s\n' 'not-json';;
            *) exit 1;;
          esac;;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/nfc-patch-info-context.json')
          case "${FAKE_PATCH_CONTEXT_STATE:-valid}" in
            valid) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","versionCode":123,"lastUpdateTime":1893456000000,"targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","model":"libre2","generation":"gen1","patchInfoSha256":"20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91","observedAtUtc":"2030-01-01T00:00:01Z","observedAtMonotonicElapsedNanos":2000000000}\n';;
            missing) printf '%s\n' 'cat: app-private context is unavailable' >&2; exit 1;;
            malformed) printf '%s\n' 'not-json';;
            stale) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","versionCode":123,"lastUpdateTime":1893456000000,"targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","model":"libre2","generation":"gen1","patchInfoSha256":"20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91","observedAtUtc":"2029-12-31T23:50:00Z","observedAtMonotonicElapsedNanos":2000000000}\n';;
            gen2) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","versionCode":123,"lastUpdateTime":1893456000000,"targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","model":"libre2","generation":"gen2","patchInfoSha256":"20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91","observedAtUtc":"2030-01-01T00:00:01Z","observedAtMonotonicElapsedNanos":2000000000}\n';;
            wrong_target) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","versionCode":123,"lastUpdateTime":1893456000000,"targetUidSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","iso15693ManufacturerPrefix":"e007","model":"libre2","generation":"gen1","patchInfoSha256":"20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91","observedAtUtc":"2030-01-01T00:00:01Z","observedAtMonotonicElapsedNanos":2000000000}\n';;
            wrong_build) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","versionCode":124,"lastUpdateTime":1893456000000,"targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","model":"libre2","generation":"gen1","patchInfoSha256":"20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91","observedAtUtc":"2030-01-01T00:00:01Z","observedAtMonotonicElapsedNanos":2000000000}\n';;
            extra) printf '{"schemaVersion":1,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","versionCode":123,"lastUpdateTime":1893456000000,"targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","model":"libre2","generation":"gen1","patchInfoSha256":"20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91","observedAtUtc":"2030-01-01T00:00:01Z","observedAtMonotonicElapsedNanos":2000000000,"unexpected":true}\n';;
            *) exit 1;;
          esac;;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/nfc-gen1-fram-capture.json')
          if [ -f "$FAKE_FRAM_SOURCE" ]; then
            if [ "${FAKE_FRAM_FINAL_READBACK_STATE:-valid}" = changed ] &&
              grep -q '"captureSessionId":"session-' "$FAKE_FRAM_SOURCE"; then
              cat "$FAKE_FRAM_SOURCE"; printf x; exit 0
            fi
            cat "$FAKE_FRAM_SOURCE"; exit 0
          fi
          case "${FAKE_FRAM_CAPTURE_STATE:-valid}" in
            missing) printf '%s\n' 'cat: app-private capture is unavailable' >&2; exit 1;;
            malformed) printf '%s\n' 'not-json';;
            valid|wrong_hash|extra|stale|bound_other)
              fram_hex=$(printf '%0688d' 0)
              patch_hash=20dc556b3e6f7cc5f9f5e614314f7979f35c01366c8f6e5708d83ea859e86c91
              [ "${FAKE_FRAM_CAPTURE_STATE:-valid}" != wrong_hash ] || patch_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
              if [ "${FAKE_FRAM_CAPTURE_STATE:-valid}" = extra ]; then extra=',"unexpected":true'; else extra=; fi
              observed=2030-01-01T00:00:03Z
              [ "${FAKE_FRAM_CAPTURE_STATE:-valid}" != stale ] || observed=2029-12-31T23:50:00Z
              capture_session=null
              [ "${FAKE_FRAM_CAPTURE_STATE:-valid}" != bound_other ] || capture_session='"session-20300101T000000Z-other"'
              printf '{"schemaVersion":2,"nativeCaptureSessionId":"nativeSession01","processSessionId":"processSession01","captureSessionId":%s,"sourceKind":"explicitLibre2Lifecycle","explicitAttemptId":"attempt_12345678","versionCode":123,"lastUpdateTime":1893456000000,"targetUidSha256":"220a97ac71f47ce45b9e870ba5f4efef43adf6ab0afa316c79826804d1b85ce1","iso15693ManufacturerPrefix":"e007","patchInfoSha256":"%s","model":"libre2","securityGeneration":"gen1","algorithmOrderUidHex":"01020304050607e0","patchInfoHex":"9d0830000000","encryptedFramHex":"%s","observedAtUtc":"%s","observedAtMonotonicElapsedNanos":4000000000%s}\n' "$capture_session" "$patch_hash" "$fram_hex" "$observed" "$extra";;
            *) exit 1;;
          esac;;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/nfc-nativeSession01-0123456789abcdef0123456789abcdef.jsonl') printf '{"sequence":9}\n';;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/ble-bleSession01-00.jsonl') printf '{"sequence":11}\n';;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/ble-bleSession01-'*) exit 1;;
        '-T run-as com.openglucose.app.debug --user 11 tee files/protocol-captures/target-unverified-nfc-grant.json.pending')
          [ "${FAKE_TEE_FAILURE:-0}" != 1 ] || exit 1
          cat >"$FAKE_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 tee files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending')
          [ "${FAKE_FRAM_TEE_FAILURE:-0}" != 1 ] || exit 1
          cat >"$FAKE_FRAM_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 tee files/protocol-captures/target-unverified-gen1-activation-grant.json.pending')
          [ "${FAKE_ACTIVATION_TEE_FAILURE:-0}" != 1 ] || exit 1
          cat >"$FAKE_ACTIVATION_GRANT";;
        '-T run-as com.openglucose.app.debug --user 11 mkdir files/protocol-captures/nfc-gen1-fram-rebind-host_'*) mkdir "$FAKE_FRAM_SOURCE.rebind-workspace";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 700 files/protocol-captures/nfc-gen1-fram-rebind-host_'*) :;;
        '-T run-as com.openglucose.app.debug --user 11 touch files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/owner-host_'*) touch "$FAKE_FRAM_SOURCE.rebind-workspace/${last_arg##*/}";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/owner-host_'*) :;;
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/owner-host_'*) :;;
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/nfc-gen1-fram-rebind-host_'*) :;;
        '-T run-as com.openglucose.app.debug --user 11 ls -1A files/protocol-captures/nfc-gen1-fram-rebind-host_'*) ls -1A "$FAKE_FRAM_SOURCE.rebind-workspace";;
        '-T run-as com.openglucose.app.debug --user 11 cp files/protocol-captures/nfc-gen1-fram-capture.json files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/original') cp "$FAKE_FRAM_SOURCE" "$FAKE_FRAM_SOURCE.rebind-workspace/original";;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/original') cat "$FAKE_FRAM_SOURCE.rebind-workspace/original";;
        '-T run-as com.openglucose.app.debug --user 11 tee files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/source.pending')
          case "${FAKE_FRAM_PENDING_UPLOAD_STATE:-valid}" in
            empty) cat >/dev/null; : >"$FAKE_FRAM_SOURCE.rebind-workspace/source.pending";;
            changed) cat >"$FAKE_FRAM_SOURCE.rebind-workspace/source.pending"; printf x >>"$FAKE_FRAM_SOURCE.rebind-workspace/source.pending";;
            *) cat >"$FAKE_FRAM_SOURCE.rebind-workspace/source.pending";;
          esac;;
        '-T run-as com.openglucose.app.debug --user 11 cat files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/source.pending') cat "$FAKE_FRAM_SOURCE.rebind-workspace/source.pending";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/source.pending') chmod 600 "$FAKE_FRAM_SOURCE.rebind-workspace/source.pending";;
        '-T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/original') chmod 600 "$FAKE_FRAM_SOURCE.rebind-workspace/original";;
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/source.pending') :;;
        '-T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/original') :;;
        '-T run-as com.openglucose.app.debug --user 11 mv files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/source.pending files/protocol-captures/nfc-gen1-fram-capture.json')
          case "${FAKE_FRAM_REBIND_MV_STATE:-success}" in
            fail_before) exit 1;;
            ambiguous) mv "$FAKE_FRAM_SOURCE.rebind-workspace/source.pending" "$FAKE_FRAM_SOURCE"; exit 1;;
            *) mv "$FAKE_FRAM_SOURCE.rebind-workspace/source.pending" "$FAKE_FRAM_SOURCE";;
          esac;;
        '-T run-as com.openglucose.app.debug --user 11 mv files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/original files/protocol-captures/nfc-gen1-fram-capture.json')
          [ "${FAKE_FRAM_ROLLBACK_FAILURE:-0}" != 1 ] || exit 1
          mv "$FAKE_FRAM_SOURCE.rebind-workspace/original" "$FAKE_FRAM_SOURCE";;
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/source.pending files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/original files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/owner-host_'*) rm -f "$FAKE_FRAM_SOURCE.rebind-workspace/source.pending" "$FAKE_FRAM_SOURCE.rebind-workspace/original" "$FAKE_FRAM_SOURCE.rebind-workspace"/owner-host_*;;
        '-T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/original files/protocol-captures/nfc-gen1-fram-rebind-host_'*'/owner-host_'*) rm -f "$FAKE_FRAM_SOURCE.rebind-workspace/original" "$FAKE_FRAM_SOURCE.rebind-workspace"/owner-host_*;;
        '-T run-as com.openglucose.app.debug --user 11 rmdir files/protocol-captures/nfc-gen1-fram-rebind-host_'*) rmdir "$FAKE_FRAM_SOURCE.rebind-workspace";;
        *) printf 'ok\n';; esac;;
      exec-out) shift; case "$*" in
        screencap*) printf png;; uiautomator*) printf '<hierarchy/>\n';; *) exit 1;; esac;;
      exec-in) exit 1;;
      *) exit 1;; esac
  SH
  File.chmod(0o700, adb)
  sleep = File.join(bin, "sleep")
  File.write(sleep, "#!/bin/sh\nexit 0\n")
  File.chmod(0o700, sleep)
  ps = File.join(bin, "ps"); File.write(ps, <<~'SH'); File.chmod(0o700, ps)
    #!/bin/sh
    pid= field=; while [ "$#" -gt 0 ]; do case "$1" in -p) pid=$2; shift 2;; -o) field=$2; shift 2;; *) shift;; esac; done
    kill -0 "$pid" 2>/dev/null || exit 1
    case "$field" in command=) printf '/bin/sh %s logcat -b all -v epoch -T 1\n' "$FAKE_ADB_PATH";; lstart=) printf 'Mon Jan  1 00:00:00 2030\n';; *) exit 1;; esac
  SH
  dart = File.join(bin, "dart")
  File.write(dart, <<~'SH')
    #!/bin/sh
    set -eu
    printf '%s\n' '{"validated":true,"model":"libre2","lifecycle":"notActivated","length":344,"evidenceStatus":"referenceVerifiedTargetUnverified"}'
  SH
  File.chmod(0o700, dart)
  fram_source=File.join(tmp,"fram-source")
  env={"PATH"=>"#{bin}:#{ENV.fetch("PATH")}","ANDROID_SERIAL"=>"FAKE_DEVICE","FAKE_AUDIT"=>audit,"FAKE_STATE"=>state,"FAKE_GRANT"=>grant,"FAKE_FRAM_GRANT"=>fram_grant,"FAKE_ACTIVATION_GRANT"=>activation_grant,"FAKE_FRAM_SOURCE"=>fram_source,"FAKE_RF_LEASE"=>rf_lease,"FAKE_ADB_PATH"=>adb}
  File.write(grant, "stale-patch-grant\n")
  File.write(fram_grant, "stale-fram-grant\n")
  File.write(activation_grant, "stale-activation-grant\n")
  start_audit_before=File.read(audit) if File.exist?(audit)
  start_audit_before ||= ""
  start_running_out,start_running_err,s=run(env,HARNESS,"start","--output-root",output)
  start_running_text="#{start_running_err}\n#{start_running_out}"
  assert(!s.success? && start_running_text.include?("run host start before Flutter") && start_running_text.include?("reuse that session"),"running app start explains the required order (status=#{s.exitstatus} text=#{start_running_text.inspect})")
  running_start_calls=File.read(audit).delete_prefix(start_audit_before)
  assert(!running_start_calls.include?("run-as") && !running_start_calls.include?("logcat"),"running app rejection precedes all app mutations and recording startup")
  assert(!start_running_text.include?("4242") && !File.exist?(rf_lease) && Dir.glob(File.join(output,"session-*")).empty?,"running app start exposes no PID, owns no RF lease, and creates no session")
  assert(File.read(grant)=="stale-patch-grant\n" && File.read(fram_grant)=="stale-fram-grant\n" && File.read(activation_grant)=="stale-activation-grant\n","running app start preserves all grant families")
  File.write(File.join(state,"running"),"0\n")
  failed_query_audit_before=File.read(audit)
  _,start_query_err,s=run(env.merge("FAKE_PIDOF_FAILURE"=>"1"),HARNESS,"start","--output-root",output)
  assert(!s.success? && start_query_err.include?("could not verify") && !start_query_err.include?("synthetic process-query failure"),"unknown process state fails closed without platform details")
  assert(!File.read(audit).delete_prefix(failed_query_audit_before).include?("run-as") && !File.exist?(rf_lease),"process-query failure cannot acquire an RF lease or change app storage")
  FileUtils.mkdir_p(rf_lease, mode: 0o700)
  start_foreign_lease_owner=File.join(rf_lease,"owner-native_start_foreign0001")
  File.write(start_foreign_lease_owner,"")
  sessions_before_busy_start=Dir.glob(File.join(output,"session-*"))
  _,start_busy_err,s=run(env,HARNESS,"start","--output-root",output)
  assert(!s.success? && start_busy_err.include?("owns the app-private lease"),"start respects active native/host RF owner")
  assert(File.read(grant)=="stale-patch-grant\n" && File.read(fram_grant)=="stale-fram-grant\n" && File.read(activation_grant)=="stale-activation-grant\n","busy start preserves all in-flight grants")
  assert(File.exist?(start_foreign_lease_owner) && Dir.glob(File.join(output,"session-*"))==sessions_before_busy_start,"busy start preserves the unknown lease and creates no session")
  File.delete(start_foreign_lease_owner)
  Dir.rmdir(rf_lease)
  out,err,s=run(env,HARNESS,"start","--output-root",output); assert(s.success?,"start #{err}"); session=out.lines.last.strip
  File.write(File.join(state,"running"),"1\n")
  assert(!File.exist?(grant) && !File.exist?(fram_grant) && !File.exist?(activation_grant),"start cleans all final/pending grant families")
  assert(!File.exist?(rf_lease),"successful start releases its exact RF lease")
  assert(File.read(File.join(session,"session.properties")).include?("mode=passive-until-separately-armed"),"mode")
  assert(File.read(File.join(session,"session.properties")).include?("capture_live_aidex=false\n"),"observation live-AiDEX binding")
  assert(File.read(File.join(session,"session.properties")).include?("android_user_id=11\n"),"current Android user binding")
  _,err,s=run(env,HARNESS,"snapshot","--session",session,"--label","01-app-idle"); assert(s.success?,"snapshot remains available after app starts #{err}")
  _,mismatch_err,s=run(env.merge("FAKE_ANDROID_USER_ID"=>"12"),HARNESS,"snapshot","--session",session,"--label","01-app-idle")
  assert(!s.success? && mismatch_err.include?("current Android user does not match this session"),"changed Android user rejection")
  assert(!mismatch_err.match?(/\b(?:11|12)\b/),"changed Android user error is identifier-free")
  _,_,s=run(env.merge("FAKE_APP_CAPTURE_STATE"=>"error"),HARNESS,"verify-app-ready","--session",session); assert(!s.success?,"error readiness")
  _,err,s=run(env,HARNESS,"verify-app-ready","--session",session); assert(s.success?,"ready #{err}")
  _,_,s=run(env.merge("FAKE_APP_CAPTURE_SERVICES"=>'["0000fde3-0000-1000-8000-00805f9b34fb","0000181f-0000-1000-8000-00805f9b34fb"]'),HARNESS,"verify-app-ready","--session",session); assert(!s.success?,"extra Libre scan filters reject readiness")
  observation=File.join(session,"target-observation.json"); observation_hash=File.join(session,"target-observation.sha256")
  _,missing_err,s=run(env.merge("FAKE_TARGET_CONTEXT_STATE"=>"missing"),HARNESS,"verify-target-observation","--session",session,"--ack-reference-e007-target-unverified")
  assert(!s.success? && missing_err.include?("current app-owned target observation is unavailable"),"remote target read failure")
  assert(!missing_err.include?("app-private context") && !missing_err.include?("ParserError"),"remote target error remains private")
  assert(!File.exist?(observation) && !File.exist?("#{observation}.pending") && !File.exist?(observation_hash) && !File.exist?("#{observation_hash}.pending"),"failed target read publishes no evidence")
  assert(File.exist?("#{observation}.stderr"),"private remote target stderr")
  _,malformed_err,s=run(env.merge("FAKE_TARGET_CONTEXT_STATE"=>"malformed"),HARNESS,"verify-target-observation","--session",session,"--ack-reference-e007-target-unverified")
  assert(!s.success? && malformed_err.include?("target observation verification failed"),"malformed target rejection")
  assert(!malformed_err.include?("ParserError") && !malformed_err.include?("not-json"),"validation details remain private")
  assert(!File.exist?(observation) && !File.exist?("#{observation}.pending") && !File.exist?(observation_hash),"malformed target publishes no evidence")
  _,stale_target_err,s=run(env.merge("FAKE_TARGET_CONTEXT_STATE"=>"stale"),HARNESS,"verify-target-observation","--session",session,"--ack-reference-e007-target-unverified")
  assert(!s.success? && stale_target_err.include?("target observation verification failed"),"stale target rejection")
  assert(!File.exist?(observation) && !File.exist?(observation_hash),"stale target publishes no evidence")
  _,err,s=run(env,HARNESS,"verify-target-observation","--session",session,"--ack-reference-e007-target-unverified"); assert(s.success?,"target #{err}")
  assert(File.exist?(observation) && File.exist?(observation_hash) && !File.exist?("#{observation}.pending") && !File.exist?("#{observation_hash}.pending"),"atomic target evidence")
  _,_,s=run(env.merge("FAKE_TARGET_CONTEXT_STATE"=>"missing"),HARNESS,"verify-target-observation","--session",session,"--ack-reference-e007-target-unverified")
  assert(!s.success? && !File.exist?(observation) && !File.exist?(observation_hash),"failed reverification invalidates old authorization evidence")
  _,err,s=run(env,HARNESS,"verify-target-observation","--session",session,"--ack-reference-e007-target-unverified"); assert(s.success?,"target reverify #{err}")

  source_session=File.join(output,"session-20300101T000000Z-source")
  source_readiness=File.join(source_session,"readiness","0001")
  FileUtils.mkdir_p(source_readiness, mode: 0o700)
  File.chmod(0o700, source_session, File.join(source_session,"readiness"), source_readiness)
  File.write(File.join(source_session,".openglucose-passive-capture"),"schema=1\n")
  File.write(File.join(source_session,"session.properties"), <<~PROPERTIES)
    schema=1
    session_id=session-20300101T000000Z-source
    created_utc=2030-01-01T00:00:00Z
    package=com.openglucose.app.debug
    device_serial_sha256=#{Digest::SHA256.hexdigest("FAKE_DEVICE")}
    android_user_id=11
    capture_profile=libre
    mode=passive-until-separately-armed
  PROPERTIES
  source_target=File.join(source_session,"target-observation.json")
  source_target_hash=File.join(source_session,"target-observation.sha256")
  FileUtils.cp(observation,source_target)
  File.write(source_target_hash,"#{Digest::SHA256.file(source_target).hexdigest}\n")
  source_selection=File.join(source_readiness,"selection.properties")
  File.write(source_selection, <<~SELECTION)
    native_session=nativeSession01
    process_session=processSession01
    process_id=4242
    version_code=123
    last_update_time=1893456000000
    ble_session=bleSession01
    ble_file=ble-bleSession01-00.jsonl
    nfc_file=nfc-nativeSession01-0123456789abcdef0123456789abcdef.jsonl
  SELECTION
  source_hashes=File.join(source_readiness,"hashes.sha256")
  File.write(source_hashes,"#{Digest::SHA256.file(source_selection).hexdigest}  selection.properties\n")
  File.chmod(0o600,*[File.join(source_session,".openglucose-passive-capture"),File.join(source_session,"session.properties"),source_target,source_target_hash,source_selection,source_hashes])
  reuse_command=[HARNESS,"arm-target-unverified-nfc-probe-from-verified-target","--session",session,"--source-session",source_session,"--ack-r3-target-unverified","--ack-reuse-verified-target"]
  File.write(grant,"preserve-while-another-owner-holds-the-rf-lease\n")
  _,lease_busy_err,s=run(env.merge("FAKE_RF_LEASE_BUSY"=>"1"),*reuse_command)
  assert(!s.success? && lease_busy_err.include?("owns the app-private lease"),"atomic host/native RF lease conflict")
  assert(File.read(grant)=="preserve-while-another-owner-holds-the-rf-lease\n","lease conflict cannot delete another owner's authorization")
  _,reuse_ack_err,s=run(env,*reuse_command[0...-1]); assert(!s.success? && reuse_ack_err.include?("--ack-reuse-verified-target"),"reuse acknowledgement")
  File.chmod(0o644,source_target)
  _,mode_err,s=run(env,*reuse_command); assert(!s.success? && mode_err.include?("prior verified target evidence is invalid"),"reuse evidence mode rejection: #{mode_err}")
  File.chmod(0o600,source_target)
  File.write(source_target_hash,"#{"a"*64}\n")
  _,hash_err,s=run(env,*reuse_command); assert(!s.success? && hash_err.include?("prior verified target evidence is invalid"),"reuse evidence hash rejection")
  File.write(source_target_hash,"#{Digest::SHA256.file(source_target).hexdigest}\n")
  File.write(fram_grant,"stale-fram-grant\n"); File.write(activation_grant,"stale-activation-grant\n")
  reuse_out,reuse_err,s=run(env.merge("FAKE_TARGET_CONTEXT_STATE"=>"missing"),*reuse_command); assert(s.success?,"reuse arm #{reuse_err}")
  assert(!File.exist?(rf_lease),"successful host arm releases its exact publication lease")
  reused=JSON.parse(File.read(grant))
  assert(reused["nativeCaptureSessionId"]=="nativeSession01" && reused["processSessionId"]=="processSession01","reuse current process binding")
  assert(reused["targetUidSha256"]==TARGET_HASH && reused["iso15693ManufacturerPrefix"]=="e007","reuse exact prior target binding")
  assert(reused["expiresAtEpochMillis"]-reused["issuedAtEpochMillis"]==90_000,"reuse grant TTL")
  assert(!File.exist?(fram_grant) && !File.exist?(activation_grant),"reuse arm cleans sibling grants")
  assert(!reuse_out.include?(TARGET_HASH) && !reuse_err.include?(TARGET_HASH),"reuse output is neutral")
  _,unknown_lease_err,s=run(env.merge("FAKE_TARGET_CONTEXT_STATE"=>"missing","FAKE_RF_UNKNOWN_EXTRA"=>"1"),*reuse_command)
  assert(!s.success? && unknown_lease_err.include?("could not release the app-private NFC RF lease"),"unknown lease entry fails host release closed")
  lease_entries=Dir.children(rf_lease)
  assert(File.exist?(grant) && lease_entries.include?("owner-native-unknown0001") && lease_entries.count { |entry| entry.start_with?("owner-host_") }==1,"uncertain lease ownership preserves the published grant and every owner entry")
  lease_entries.each { |entry| File.delete(File.join(rf_lease,entry)) }
  Dir.rmdir(rf_lease)
  _,fram_replay_err,s=run(env,HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--source-session",source_session,"--ack-reuse-verified-target","--ack-r3-gen1-fram-read")
  assert(!s.success? && fram_replay_err.include?("reuse command") && File.exist?(grant),"replayed evidence cannot arm FRAM or clear patch grant")
  _,_,s=run(env,HARNESS,"arm-target-unverified-nfc-probe","--session",session); assert(!s.success?,"R3 ack")
  _,tee_err,s=run(env.merge("FAKE_TEE_FAILURE"=>"1"),HARNESS,"arm-target-unverified-nfc-probe","--session",session,"--ack-r3-target-unverified")
  assert(!s.success? && tee_err.include?("could not stage the session/build-bound target-unverified-nfc grant") && !File.exist?(grant),"remote grant write failure")
  _,err,s=run(env,HARNESS,"arm-target-unverified-nfc-probe","--session",session,"--ack-r3-target-unverified"); assert(s.success?,"arm #{err}")
  value=JSON.parse(File.read(grant)); keys=%w[schemaVersion nonce nativeCaptureSessionId processSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix operation sessionId issuedAtEpochMillis expiresAtEpochMillis]
  assert(value.keys==keys,"patch grant exact 12 fields")
  assert(value["operation"]=="target_unverified_patch_info_probe","patch grant operation")
  assert(value["sessionId"]==File.basename(session),"patch grant session binding")
  assert(value["versionCode"]==123 && value["lastUpdateTime"]==1_893_456_000_000,"patch grant build binding")
  assert(value["targetUidSha256"]==TARGET_HASH && value["iso15693ManufacturerPrefix"]=="e007","patch grant target binding")
  assert(value["expiresAtEpochMillis"]-value["issuedAtEpochMillis"]==90_000,"patch grant TTL")
  assert((File.stat(grant).mode & 0o777)==0o600,"patch grant mode")
  assert(!File.exist?(fram_grant),"patch arm excludes FRAM grant")

  _,fram_ack_err,s=run(env,HARNESS,"arm-target-unverified-gen1-fram-read","--session",session)
  assert(!s.success? && fram_ack_err.include?("--ack-r3-gen1-fram-read"),"FRAM grant requires distinct acknowledgement")
  _,_,s=run(env,HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--ack-r3-target-unverified")
  assert(!s.success? && File.exist?(grant),"patch acknowledgement cannot arm or clear FRAM grant")
  %w[missing malformed stale gen2 wrong_target wrong_build extra].each do |state_name|
    _,context_err,s=run(env.merge("FAKE_PATCH_CONTEXT_STATE"=>state_name),HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--ack-r3-gen1-fram-read")
    assert(!s.success?,"FRAM #{state_name} patch context rejection")
    assert(!context_err.include?("not-json") && !context_err.include?(TARGET_HASH) && !context_err.include?(PATCH_HASH),"FRAM #{state_name} error remains private")
    assert(!File.exist?(grant) && !File.exist?(fram_grant),"FRAM #{state_name} failure leaves no grant")
  end
  _,fram_tee_err,s=run(env.merge("FAKE_FRAM_TEE_FAILURE"=>"1"),HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--ack-r3-gen1-fram-read")
  assert(!s.success? && fram_tee_err.include?("could not stage the session/build-bound target-unverified-gen1-fram-read grant") && !File.exist?(fram_grant),"FRAM remote grant write failure")
  _,fram_mv_err,s=run(env.merge("FAKE_FRAM_MV_FAILURE"=>"1"),HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--ack-r3-gen1-fram-read")
  assert(!s.success? && fram_mv_err.include?("could not atomically publish") && !File.exist?(grant) && !File.exist?(fram_grant),"FRAM publish rollback cleans both grants")
  _,err,s=run(env,HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--ack-r3-gen1-fram-read"); assert(s.success?,"FRAM arm #{err}")
  fram_value=JSON.parse(File.read(fram_grant))
  fram_keys=%w[schemaVersion nonce nativeCaptureSessionId processSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix patchInfoSha256 operation sessionId issuedAtEpochMillis expiresAtEpochMillis]
  assert(fram_value.keys==fram_keys,"FRAM grant exact 13 fields")
  assert(fram_value["operation"]=="target_unverified_gen1_fram_read","FRAM grant operation")
  assert(fram_value["sessionId"]==File.basename(session),"FRAM grant session binding")
  assert(fram_value["versionCode"]==123 && fram_value["lastUpdateTime"]==1_893_456_000_000,"FRAM grant build binding")
  assert(fram_value["targetUidSha256"]==TARGET_HASH && fram_value["iso15693ManufacturerPrefix"]=="e007","FRAM grant target binding")
  assert(fram_value["patchInfoSha256"]==PATCH_HASH,"FRAM grant patch binding")
  assert(fram_value["expiresAtEpochMillis"]-fram_value["issuedAtEpochMillis"]==300_000,"FRAM grant TTL")
  assert((File.stat(fram_grant).mode & 0o777)==0o600,"FRAM grant mode")
  assert(!File.exist?(grant),"FRAM arm excludes patch grant")

  _,disarm_partial_err,s=run(env.merge("FAKE_RF_OWNER_CHMOD_FAILURE"=>"1"),HARNESS,"disarm-target-unverified-nfc-probe","--session",session)
  assert(!s.success? && disarm_partial_err.include?("could not protect the app-private NFC RF lease owner"),"partial disarm lease acquisition fails closed")
  assert(File.exist?(fram_grant) && !File.exist?(rf_lease),"partial disarm acquisition releases only its exact owner and preserves authorization")
  _,disarm_busy_err,s=run(env.merge("FAKE_RF_LEASE_BUSY"=>"1"),HARNESS,"disarm-target-unverified-nfc-probe","--session",session)
  assert(!s.success? && disarm_busy_err.include?("owns the app-private lease"),"disarm respects active native/host RF owner")
  assert(File.exist?(fram_grant),"busy disarm cannot delete in-flight authorization")
  _,err,s=run(env,HARNESS,"disarm-target-unverified-nfc-probe","--session",session); assert(s.success?,"cross-disarm #{err}")
  assert(!File.exist?(grant) && !File.exist?(fram_grant),"either disarm cleans both grant families")
  _,err,s=run(env,HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--ack-r3-gen1-fram-read"); assert(s.success?,"FRAM rearm #{err}")
  _,err,s=run(env,HARNESS,"arm-target-unverified-nfc-probe","--session",session,"--ack-r3-target-unverified"); assert(s.success?,"patch rearm #{err}")
  assert(File.exist?(grant) && !File.exist?(fram_grant),"patch rearm removes FRAM grant")
  _,err,s=run(env,HARNESS,"arm-target-unverified-gen1-fram-read","--session",session,"--ack-r3-gen1-fram-read"); assert(s.success?,"FRAM final rearm #{err}")
  assert(!File.exist?(grant) && File.exist?(fram_grant),"FRAM rearm removes patch grant")

  collect_env=env.merge("FAKE_TARGET_CONTEXT_STATE"=>"fram","FAKE_CAPTURE_SESSION_ID"=>File.basename(session))
  missing_audit_offset=File.size(audit)
  _,missing_capture_err,s=run(collect_env.merge("FAKE_FRAM_CAPTURE_STATE"=>"missing"),HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && missing_capture_err.include?("capture is absent or unreadable"),"missing private FRAM capture rejection")
  missing_audit=File.binread(audit).byteslice(missing_audit_offset..-1)
  missing_audit_lines=missing_audit.lines
  missing_source_index=missing_audit_lines.index { |line| line.include?("cat files/protocol-captures/nfc-gen1-fram-capture.json") }
  assert(!missing_source_index.nil?,"missing FRAM source is checked directly")
  assert(missing_audit_lines.drop(missing_source_index+1).none? { |line| line.include?("nfc-nativeSession01-") && line.include?(".jsonl") },"missing FRAM source never falls back to trace recovery")
  legacy_backup="#{fram_source}.rebind-original"
  File.binwrite(legacy_backup,"pre-existing recovery bytes\n")
  _,_,s=run(collect_env.merge("FAKE_FRAM_CAPTURE_STATE"=>"missing"),HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && File.binread(legacy_backup)=="pre-existing recovery bytes\n","missing source preserves every pre-existing recovery backup")
  File.delete(legacy_backup)
  %w[malformed wrong_hash extra stale].each do |state_name|
    _,collect_err,s=run(collect_env.merge("FAKE_FRAM_CAPTURE_STATE"=>state_name),HARNESS,"collect-gen1-fram-capture","--session",session)
    assert(!s.success?,"#{state_name} FRAM capture rejection")
    assert(!collect_err.include?("not-json") && !collect_err.include?(ALGORITHM_UID_HEX) && !collect_err.include?(PATCH_INFO_HEX),"#{state_name} FRAM capture error remains private")
  end
  _,cross_session_err,s=run(collect_env.merge("FAKE_FRAM_CAPTURE_STATE"=>"bound_other"),HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && cross_session_err.include?("not bound to this target/build/session"),"FRAM capture session binding")

  # Materialize the exact app-private schema-v2 source so every failed rebind
  # can prove that its original bytes were retained.
  original_source,source_err,s=run(
    collect_env,
    adb,
    "shell","-n","-T","run-as","com.openglucose.app.debug","--user","11",
    "cat","files/protocol-captures/nfc-gen1-fram-capture.json",
  )
  assert(s.success? && source_err.empty? && !original_source.empty?,"materialized exact explicit FRAM source")
  File.binwrite(fram_source,original_source)
  File.write(File.join(state,"count"),"60\n")
  restricted=File.join(session,"restricted")
  collected=File.join(restricted,"nfc-gen1-fram-capture.json")
  collected_hash=File.join(restricted,"nfc-gen1-fram-capture.sha256")
  fake_rebind_workspace="#{fram_source}.rebind-workspace"

  FileUtils.mkdir(fake_rebind_workspace)
  preexisting_workspace_marker=File.join(fake_rebind_workspace,"pre-existing-owner")
  File.binwrite(preexisting_workspace_marker,"preserve\n")
  _,workspace_err,s=run(collect_env,HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && workspace_err.include?("exclusively create"),"pre-existing rebind workspace is refused")
  assert(File.binread(preexisting_workspace_marker)=="preserve\n" && !File.exist?(rf_lease),"unowned rebind workspace is preserved and exact lease is released")
  FileUtils.remove_entry(fake_rebind_workspace)

  %w[empty changed].each do |upload_state|
    _,stage_err,s=run(collect_env.merge("FAKE_FRAM_PENDING_UPLOAD_STATE"=>upload_state),HARNESS,"collect-gen1-fram-capture","--session",session)
    assert(!s.success? && stage_err.include?("staged app-owned Gen1 FRAM rebind changed during upload"),"#{upload_state} staged rebind is rejected before promotion")
    assert(File.binread(fram_source)==original_source,"#{upload_state} staged rebind preserves the exact original source")
    assert(!File.exist?(fake_rebind_workspace),"#{upload_state} staged rebind cleans its exact private workspace")
    assert(!File.exist?(collected) && !File.exist?(collected_hash) && !File.exist?(rf_lease),"#{upload_state} staged rebind publishes nothing and releases its exact lease")
  end

  _,ambiguous_err,s=run(collect_env.merge("FAKE_FRAM_REBIND_MV_STATE"=>"ambiguous"),HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && ambiguous_err.include?("could not atomically publish"),"ambiguous device-side rename fails collection")
  assert(File.binread(fram_source)==original_source && !File.exist?(fake_rebind_workspace),"ambiguous rename restores the byte-exact original")
  assert(!File.exist?(collected) && !File.exist?(collected_hash) && !File.exist?(rf_lease),"successful ambiguous-rename rollback publishes nothing and releases its exact lease")

  _,readback_err,s=run(collect_env.merge("FAKE_FRAM_FINAL_READBACK_STATE"=>"changed"),HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && readback_err.include?("changed during publication"),"changed final rebind readback fails collection")
  assert(File.binread(fram_source)==original_source && !File.exist?(rf_lease),"changed final readback restores the exact original and releases its lease")

  _,rollback_err,s=run(
    collect_env.merge("FAKE_FRAM_REBIND_MV_STATE"=>"ambiguous","FAKE_FRAM_ROLLBACK_FAILURE"=>"1"),
    HARNESS,"collect-gen1-fram-capture","--session",session,
  )
  assert(!s.success? && rollback_err.include?("lease remains quarantined"),"unproven rollback fails closed")
  assert(File.exist?(File.join(fake_rebind_workspace,"original")) && File.exist?(rf_lease),"unproven rollback retains the exact original backup and RF lease")
  assert(Dir.children(rf_lease).count { |entry| entry.start_with?("owner-host_") }==1,"rollback quarantine retains its exact host owner")
  assert(!File.exist?(collected) && !File.exist?(collected_hash),"unproven rollback publishes no host artifact")
  FileUtils.mv(File.join(fake_rebind_workspace,"original"),fram_source,force:true)
  FileUtils.remove_entry(fake_rebind_workspace)
  Dir.children(rf_lease).each { |entry| File.delete(File.join(rf_lease,entry)) }
  Dir.rmdir(rf_lease)

  _,release_err,s=run(collect_env.merge("FAKE_RF_UNKNOWN_EXTRA"=>"1"),HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && release_err.include?("could not release the exact app-private NFC RF lease"),"FRAM collection fails closed if exact lease release is uncertain")
  assert(!File.exist?(collected) && !File.exist?(collected_hash),"lease release failure publishes no collected artifact")
  assert(File.exist?(File.join(rf_lease,"owner-native-unknown0001")),"lease release failure preserves an unknown owner")
  FileUtils.rm_f(Dir.glob(File.join(rf_lease,"owner-*")))
  Dir.rmdir(rf_lease)
  collect_out,err,s=run(collect_env,HARNESS,"collect-gen1-fram-capture","--session",session); assert(s.success?,"FRAM collection #{err}")
  assert(File.exist?(collected) && File.exist?(collected_hash),"atomic FRAM artifact and hash publication")
  assert(!File.exist?("#{collected}.pending") && !File.exist?("#{collected_hash}.pending"),"no FRAM collection staging residue")
  assert((File.stat(restricted).mode & 0o777)==0o700 && (File.stat(collected).mode & 0o777)==0o600 && (File.stat(collected_hash).mode & 0o777)==0o600,"private FRAM artifact modes")
  assert(File.read(collected_hash).strip==Digest::SHA256.file(collected).hexdigest,"FRAM artifact hash")
  assert(File.binread(fram_source)==File.binread(collected),"successful rebind upload and final readback are byte-exact")
  collect_audit_lines=File.readlines(audit,chomp:true)
  stage_index=collect_audit_lines.rindex { |line| line.include?("tee files/protocol-captures/nfc-gen1-fram-rebind-host_") && line.end_with?("/source.pending") }
  pending_read_index=collect_audit_lines.rindex { |line| line.include?("cat files/protocol-captures/nfc-gen1-fram-rebind-host_") && line.end_with?("/source.pending") }
  promote_index=collect_audit_lines.rindex { |line| line.include?("mv files/protocol-captures/nfc-gen1-fram-rebind-host_") && line.end_with?("/source.pending files/protocol-captures/nfc-gen1-fram-capture.json") }
  assert(!stage_index.nil? && !pending_read_index.nil? && !promote_index.nil? && stage_index < pending_read_index && pending_read_index < promote_index,"rebind stages and reads back exact bytes before promotion")
  assert(collect_audit_lines.any? { |line| line.start_with?("shell -n am get-current-user") },"ADB user preflight disables stdin consumption")
  assert(collect_out.lines.length==2 && collect_out.include?("COLLECTED:") && collect_out.include?("artifact_sha256="),"neutral FRAM collection output")
  assert(!collect_out.include?(ALGORITHM_UID_HEX) && !collect_out.include?(PATCH_INFO_HEX) && !collect_out.include?(TARGET_HASH),"FRAM raw material is not printed")
  _,duplicate_err,s=run(collect_env,HARNESS,"collect-gen1-fram-capture","--session",session)
  assert(!s.success? && duplicate_err.include?("already collected or pending"),"FRAM collection is non-overwriting")

  # Start a fresh bounded fake-clock window for the activation contract. The
  # preceding negative collection matrix intentionally consumes many status
  # samples; real app observations would be refreshed during that interval.
  File.write(File.join(state, "count"), "60\n")
  _,activation_ack_err,s=run(env,HARNESS,"arm-target-unverified-gen1-activation","--session",session)
  assert(!s.success? && activation_ack_err.include?("--ack-r3-gen1-activation"),"activation requires distinct acknowledgement")
  _,activation_tee_err,s=run(env.merge("FAKE_ACTIVATION_TEE_FAILURE"=>"1"),HARNESS,"arm-target-unverified-gen1-activation","--session",session,"--ack-r3-gen1-activation")
  assert(!s.success? && activation_tee_err.include?("could not stage the session/build-bound target-unverified-gen1-activation grant") && !File.exist?(activation_grant),"activation remote grant write failure")
  _,activation_mv_err,s=run(env.merge("FAKE_ACTIVATION_MV_FAILURE"=>"1"),HARNESS,"arm-target-unverified-gen1-activation","--session",session,"--ack-r3-gen1-activation")
  assert(!s.success? && activation_mv_err.include?("could not atomically publish") && !File.exist?(grant) && !File.exist?(fram_grant) && !File.exist?(activation_grant),"activation publish rollback cleans all grants")
  _,err,s=run(env,HARNESS,"arm-target-unverified-gen1-activation","--session",session,"--ack-r3-gen1-activation"); assert(s.success?,"activation arm #{err}")
  activation_value=JSON.parse(File.read(activation_grant))
  activation_keys=%w[schemaVersion nonce nativeCaptureSessionId processSessionId versionCode lastUpdateTime targetUidSha256 iso15693ManufacturerPrefix patchInfoSha256 model securityGeneration operation sessionId attemptId sourceFramCaptureSha256 sourceEncryptedFramSha256 validatedLifecycle plannedRequestSha256 issuedAtEpochMillis expiresAtEpochMillis]
  assert(activation_value.keys==activation_keys,"activation grant exact 20 fields")
  assert(activation_value["operation"]=="target_unverified_gen1_activation" && activation_value["model"]=="libre2" && activation_value["securityGeneration"]=="gen1","activation closed operation/model")
  assert(activation_value["attemptId"].match?(/\Aactivation-[0-9a-f]{32}\z/),"activation attempt ID")
  assert(activation_value["sourceFramCaptureSha256"]==Digest::SHA256.file(collected).hexdigest,"activation source artifact binding")
  assert(activation_value["sourceEncryptedFramSha256"]=="7c7f15ed27de2f3a51d1da31356b27ea1be15370faa3caab96606e5390ebbd0e","activation encrypted FRAM binding")
  assert(activation_value["validatedLifecycle"]=="notActivated","activation lifecycle gate")
  assert(activation_value["plannedRequestSha256"]=="5f0747a31248f329efa25b857cdd206c2af7f64f8bf0c5c2a043e623b260f2b0","activation request parity hash")
  assert(activation_value["expiresAtEpochMillis"]-activation_value["issuedAtEpochMillis"]==90_000,"activation grant TTL")
  assert((File.stat(activation_grant).mode & 0o777)==0o600 && !File.exist?(grant) && !File.exist?(fram_grant),"activation grant is private and excludes siblings")
  _,journal_err,s=run(env.merge("FAKE_ACTIVATION_JOURNAL_PRESENT"=>"1"),HARNESS,"arm-target-unverified-gen1-activation","--session",session,"--ack-r3-gen1-activation")
  assert(!s.success? && journal_err.include?("reviewed reconciliation") && !File.exist?(activation_grant),"existing activation journal blocks retry and cleans grants")
  _,err,s=run(env,HARNESS,"arm-target-unverified-gen1-activation","--session",session,"--ack-r3-gen1-activation"); assert(s.success?,"activation rearm #{err}")
  _,err,s=run(env,HARNESS,"disarm-target-unverified-gen1-activation","--session",session); assert(s.success?,"activation disarm #{err}")
  assert(!File.exist?(activation_grant),"activation disarm removes grant without touching a journal")
  _,err,s=run(env,HARNESS,"snapshot","--session",session,"--label","01-app-idle"); assert(s.success?,"snapshot #{err}")
  snap=Dir.glob(File.join(session,"snapshots","*-01-app-idle")).first; names=Dir.glob(File.join(snap,"app-jsonl","*.jsonl")).map { |path| File.basename(path) }
  assert(names.sort==["ble-bleSession01-00.jsonl","nfc-nativeSession01-0123456789abcdef0123456789abcdef.jsonl"],"bound export")
  meta=File.read(File.join(snap,"metadata.txt")); assert(meta.include?("nfc_last_sequence=9")&&meta.include?("ble_last_sequence=11"),"separate seq")
  File.write(grant,"stale-patch-grant\n"); File.write(fram_grant,"stale-fram-grant\n"); File.write(activation_grant,"stale-activation-grant\n")
  FileUtils.mkdir_p(rf_lease, mode: 0o700); foreign_lease_owner=File.join(rf_lease,"owner-native_foreign0001"); File.write(foreign_lease_owner,"")
  _,stop_busy_err,s=run(env,HARNESS,"stop","--session",session)
  assert(!s.success? && stop_busy_err.include?("owns the app-private lease"),"stop respects active native/host RF owner")
  assert(File.read(grant)=="stale-patch-grant\n" && File.read(fram_grant)=="stale-fram-grant\n" && File.read(activation_grant)=="stale-activation-grant\n","busy stop preserves all in-flight grants")
  assert(File.exist?(foreign_lease_owner) && File.read(File.join(session,"state")).strip=="active" && File.read(File.join(state,"running")).strip=="1","busy stop preserves the unknown lease and active session")
  File.delete(foreign_lease_owner); Dir.rmdir(rf_lease)
  _,err,s=run(env,HARNESS,"stop","--session",session); assert(s.success?,"stop #{err}")
  assert(!File.exist?(grant) && !File.exist?(fram_grant) && !File.exist?(activation_grant),"stop cleans all final/pending grant families")
  assert(!File.exist?(rf_lease),"successful stop releases its exact RF lease")
  assert(File.read(File.join(session,"stop-status-result.txt")).strip=="stale-unchanged","unchanged stopped status")
  File.write(File.join(state,"running"),"0\n"); File.write(File.join(state,"count"),"0\n")
  out,err,s=run(env,HARNESS,"start","--output-root",output); assert(s.success?,"second start #{err}"); absent_session=out.lines.last.strip
  File.write(File.join(state,"running"),"1\n")
  _,err,s=run(env.merge("FAKE_STATUS_ABSENT_WHEN_STOPPED"=>"1"),HARNESS,"stop","--session",absent_session); assert(s.success?,"absent-status stop #{err}")
  assert(File.read(File.join(absent_session,"stop-status-result.txt")).strip=="absent-after-stop","absent stopped status")
  File.write(File.join(state,"running"), "0\n"); File.write(File.join(state,"count"), "0\n")
  live_env=env.merge("OPENGLUCOSE_CAPTURE_LIVE_AIDEX"=>"true")
  out,err,s=run(live_env,HARNESS,"start","--output-root",output); assert(s.success?,"live-AiDEX start #{err}"); live_session=out.lines.last.strip
  File.write(File.join(state,"running"),"1\n")
  live_properties=File.read(File.join(live_session,"session.properties"))
  assert(live_properties.include?("capture_live_aidex=true\n"),"live-AiDEX session binding")
  assert(live_properties.include?("mode=full-ui-live-aidex-plus-protocol-capture\n"),"live-AiDEX mode")
  _,err,s=run(live_env,HARNESS,"verify-app-ready","--session",live_session); assert(s.success?,"live-AiDEX union readiness #{err}")
  live_selection=File.read(File.join(live_session,"readiness","0001","selection.properties"))
  assert(live_selection.include?("capture_live_aidex=true\n"),"live-AiDEX readiness binding")
  fde3_only='["0000fde3-0000-1000-8000-00805f9b34fb"]'
  _,_,s=run(live_env.merge("FAKE_APP_CAPTURE_SERVICES"=>fde3_only),HARNESS,"verify-app-ready","--session",live_session); assert(!s.success?,"live-AiDEX mode rejects FDE3-only readiness")
  reversed_union='["0000181f-0000-1000-8000-00805f9b34fb","0000fde3-0000-1000-8000-00805f9b34fb"]'
  _,_,s=run(live_env.merge("FAKE_APP_CAPTURE_SERVICES"=>reversed_union),HARNESS,"verify-app-ready","--session",live_session); assert(!s.success?,"live-AiDEX mode requires exact service order")
  extra_union='["0000fde3-0000-1000-8000-00805f9b34fb","0000181f-0000-1000-8000-00805f9b34fb","0000180d-0000-1000-8000-00805f9b34fb"]'
  _,_,s=run(live_env.merge("FAKE_APP_CAPTURE_SERVICES"=>extra_union),HARNESS,"verify-app-ready","--session",live_session); assert(!s.success?,"live-AiDEX mode rejects extra scan services")
  _,mode_err,s=run(env,HARNESS,"verify-app-ready","--session",live_session); assert(!s.success? && mode_err.include?("capture live-AiDEX mode does not match this session"),"live-AiDEX session-mode mismatch")
  _,err,s=run(live_env,HARNESS,"stop","--session",live_session); assert(s.success?,"live-AiDEX stop #{err}")
  File.write(File.join(state,"running"), "0\n"); File.write(File.join(state,"count"), "0\n")
  out,err,s=run(env,YUWELL_HARNESS,"start","--output-root",output); assert(s.success?,"Yuwell start #{err}"); yuwell_session=out.lines.last.strip
  File.write(File.join(state,"running"),"1\n")
  properties=File.read(File.join(yuwell_session,"session.properties")); assert(properties.include?("capture_profile=yuwell_anytime_passive\n"),"Yuwell profile binding"); assert(properties.include?("capture_live_aidex=false\n"),"Yuwell live-AiDEX binding")
  _,err,s=run(env,YUWELL_HARNESS,"verify-app-ready","--session",yuwell_session); assert(s.success?,"Yuwell unfiltered readiness #{err}")
  _,_,s=run(env.merge("FAKE_APP_CAPTURE_SERVICES"=>'["0000fde3-0000-1000-8000-00805f9b34fb"]'),YUWELL_HARNESS,"verify-app-ready","--session",yuwell_session); assert(!s.success?,"Yuwell filtered scan rejects readiness")
  _,profile_err,s=run(env,HARNESS,"verify-app-ready","--session",yuwell_session); assert(!s.success? && profile_err.include?("capture profile does not match this session"),"cross-profile session rejection")
  nfc_audit_before=File.read(audit)
  _,observation_err,s=run(env,YUWELL_HARNESS,"verify-target-observation","--session",yuwell_session,"--ack-reference-e007-target-unverified"); assert(!s.success? && observation_err.include?("Libre NFC target observation is disabled"),"Yuwell NFC observation rejection")
  _,nfc_err,s=run(env,YUWELL_HARNESS,"arm-target-unverified-nfc-probe","--session",yuwell_session,"--ack-r3-target-unverified"); assert(!s.success? && nfc_err.include?("Libre NFC probing is disabled"),"Yuwell NFC probe rejection")
  _,disarm_err,s=run(env,YUWELL_HARNESS,"disarm-target-unverified-nfc-probe","--session",yuwell_session); assert(!s.success? && disarm_err.include?("Libre NFC probing is disabled"),"Yuwell NFC disarm rejection")
  _,fram_err,s=run(env,YUWELL_HARNESS,"arm-target-unverified-gen1-fram-read","--session",yuwell_session,"--ack-r3-gen1-fram-read"); assert(!s.success? && fram_err.include?("Libre NFC probing is disabled"),"Yuwell FRAM arm rejection")
  _,fram_disarm_err,s=run(env,YUWELL_HARNESS,"disarm-target-unverified-gen1-fram-read","--session",yuwell_session); assert(!s.success? && fram_disarm_err.include?("Libre NFC probing is disabled"),"Yuwell FRAM disarm rejection")
  _,fram_collect_err,s=run(env,YUWELL_HARNESS,"collect-gen1-fram-capture","--session",yuwell_session); assert(!s.success? && fram_collect_err.include?("Libre Gen1 FRAM collection is disabled"),"Yuwell FRAM collection rejection")
  _,activation_err,s=run(env,YUWELL_HARNESS,"arm-target-unverified-gen1-activation","--session",yuwell_session,"--ack-r3-gen1-activation"); assert(!s.success? && activation_err.include?("Libre NFC probing is disabled"),"Yuwell activation arm rejection")
  _,activation_disarm_err,s=run(env,YUWELL_HARNESS,"disarm-target-unverified-gen1-activation","--session",yuwell_session); assert(!s.success? && activation_disarm_err.include?("Libre NFC probing is disabled"),"Yuwell activation disarm rejection")
  assert(File.read(audit)==nfc_audit_before,"Yuwell wrapper makes no Libre NFC ADB call")
  _,err,s=run(env,YUWELL_HARNESS,"stop","--session",yuwell_session); assert(s.success?,"Yuwell stop #{err}")
  calls=File.read(audit); assert(calls.include?("shell -n am force-stop --user 11 com.openglucose.app.debug"),"user-bound force stop"); assert(calls.include?("sync files/protocol-captures/target-unverified-nfc-grant.json.pending"),"patch grant file sync"); assert(calls.include?("sync files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending"),"FRAM grant file sync"); assert(!calls.include?(" sh -c "),"sh-c"); assert(!calls.match?(/run-as .*find/),"recursive find")
  assert(calls.include?("shell -n -T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-nfc-grant.json"),"user-bound fixed grant cleanup")
  assert(calls.include?("shell -n -T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-nfc-grant.json.pending"),"patch pending cleanup")
  assert(calls.include?("shell -n -T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-fram-read-grant.json"),"FRAM fixed grant cleanup")
  assert(calls.include?("shell -n -T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending"),"FRAM pending cleanup")
  assert(calls.include?("shell -n -T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-activation-grant.json"),"activation fixed grant cleanup")
  assert(calls.include?("shell -n -T run-as com.openglucose.app.debug --user 11 rm -f files/protocol-captures/target-unverified-gen1-activation-grant.json.pending"),"activation pending cleanup")
  assert(!calls.match?(/rm -f .*nfc-gen1-activation-journal/),"host controls never remove the activation journal")
  fram_tee="shell -T run-as com.openglucose.app.debug --user 11 tee files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending"
  fram_chmod="shell -n -T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending"
  fram_sync="shell -n -T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending"
  fram_mv="shell -n -T run-as com.openglucose.app.debug --user 11 mv files/protocol-captures/target-unverified-gen1-fram-read-grant.json.pending files/protocol-captures/target-unverified-gen1-fram-read-grant.json"
  fram_flow=[calls.rindex(fram_tee),calls.rindex(fram_chmod),calls.rindex(fram_sync),calls.rindex(fram_mv)]
  assert(fram_flow.none?(&:nil?) && fram_flow.each_cons(2).all? { |left,right| left < right },"FRAM stage/chmod/fsync/rename order")
  activation_tee="shell -T run-as com.openglucose.app.debug --user 11 tee files/protocol-captures/target-unverified-gen1-activation-grant.json.pending"
  activation_chmod="shell -n -T run-as com.openglucose.app.debug --user 11 chmod 600 files/protocol-captures/target-unverified-gen1-activation-grant.json.pending"
  activation_sync="shell -n -T run-as com.openglucose.app.debug --user 11 sync files/protocol-captures/target-unverified-gen1-activation-grant.json.pending"
  activation_mv="shell -n -T run-as com.openglucose.app.debug --user 11 mv files/protocol-captures/target-unverified-gen1-activation-grant.json.pending files/protocol-captures/target-unverified-gen1-activation-grant.json"
  activation_flow=[calls.rindex(activation_tee),calls.rindex(activation_chmod),calls.rindex(activation_sync),calls.rindex(activation_mv)]
  assert(activation_flow.none?(&:nil?) && activation_flow.each_cons(2).all? { |left,right| left < right },"activation stage/chmod/fsync/rename order")
  run_as_calls=calls.lines.grep(/\brun-as\b/)
  assert(!run_as_calls.empty? && run_as_calls.all? { |line| line.match?(/\Ashell (?:-n )?-T run-as com\.openglucose\.app\.debug --user 11 /) },"all run-as calls use shell-v2 without a PTY and bind the current user")
  assert(run_as_calls.reject { |line| line.include?(" tee ") }.all? { |line| line.start_with?("shell -n -T ") },"all non-upload run-as calls disable stdin")
  assert(run_as_calls.select { |line| line.include?(" tee ") }.all? { |line| line.start_with?("shell -T ") },"only intended uploads keep adb shell stdin open")
  [/(^| )install( |$)/,/settings (put|delete)/,/logcat .* -c( |$)/,/(createBond|removeBond|pair|unpair)/i,/transceive/i,/0x(?:23|b3|20)/i,/(enable.streaming|fallback)/i].each{|p|assert(!calls.match?(p),"forbidden #{p}")}
  _,err,s=run(env,HARNESS,"doctor","--output-root",File.join(ROOT,"capture-output")); assert(!s.success?&&err.include?("outside every Git worktree"),"Git output")
  _,err,s=run(env.merge("FAKE_ANDROID_USER_ID"=>"01"),HARNESS,"doctor","--output-root",File.join(tmp,"malformed-user-output")); assert(!s.success?&&err.include?("current Android user ID is not canonical"),"strict current-user validation")
  _,err,s=run(env.merge("OPENGLUCOSE_CAPTURE_LIVE_AIDEX"=>"1"),HARNESS,"doctor","--output-root",File.join(tmp,"invalid-live-mode-output")); assert(!s.success?&&err.include?("OPENGLUCOSE_CAPTURE_LIVE_AIDEX must be true or false"),"strict live-AiDEX environment validation")
end
puts "Libre protocol capture contract checks passed."
