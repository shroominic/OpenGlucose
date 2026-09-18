#!/bin/sh
# Runs one assertion-bearing GS1 harness on a physical device and records the
# redacted evidence artifact the harness emits.
#
#   make cbio-gs1-evidence DEVICE_ID=<adb serial>
#   CBIO_EVIDENCE_LOG=<captured log> make cbio-gs1-evidence
#
# The device run is bounded by the harness itself. This script never sends a
# frame, never reads the sensor, and never writes a field the harness did not
# already report.
set -eu
umask 077

gs1_script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
gs1_repository_root=$(CDPATH='' cd -P "$gs1_script_dir/.." && pwd)
gs1_harness=${HARNESS:-openhealth/integration_test/cbio_glucose_authenticated_test.dart}
gs1_device_id=${DEVICE_ID:-}
gs1_evidence_dir=${EVIDENCE_DIR:-$gs1_repository_root/../evidence}
gs1_reused_log=${CBIO_EVIDENCE_LOG:-}
gs1_stream_seconds=${CBIO_STREAM_SECONDS:-20}
gs1_app_package=${CBIO_APP_PACKAGE:-com.openglucose.app.debug}
gs1_log=
gs1_status=0

gs1_info() {
  printf '%s\n' "$*"
}

gs1_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v flutter >/dev/null 2>&1 ||
  gs1_die 'flutter is not on PATH; run make bootstrap with the pinned toolchain'
command -v dart >/dev/null 2>&1 ||
  gs1_die 'dart is not on PATH; run make bootstrap with the pinned toolchain'

case "$gs1_harness" in
  openhealth/*) ;;
  *) gs1_die 'HARNESS must be an application-relative path under openhealth/' ;;
esac
[ -f "$gs1_repository_root/$gs1_harness" ] ||
  gs1_die "harness not found: $gs1_harness"

if [ -n "$gs1_reused_log" ]; then
  [ -f "$gs1_reused_log" ] ||
    gs1_die "CBIO_EVIDENCE_LOG is not a readable file: $gs1_reused_log"
  gs1_log=$gs1_reused_log
  gs1_info "Re-recording from the captured device log: $gs1_log"
else
  [ -n "$gs1_device_id" ] ||
    gs1_die 'DEVICE_ID=<adb serial> is required, or set CBIO_EVIDENCE_LOG=<file> to re-record an existing run'
  gs1_revision=$(git -C "$gs1_repository_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
  if [ -n "$(git -C "$gs1_repository_root" status --porcelain 2>/dev/null)" ]; then
    gs1_revision="$gs1_revision-dirty"
  fi
  gs1_log=$(mktemp "${TMPDIR:-/tmp}/openglucose-gs1-evidence.XXXXXX")
  gs1_info "Running $gs1_harness on $gs1_device_id (revision $gs1_revision)"
  gs1_info 'The harness sends only its bounded allowed frames; see the harness header.'
  set +e
  (
    cd "$gs1_repository_root/openhealth"
    flutter test --no-pub "${gs1_harness#openhealth/}" -d "$gs1_device_id" \
      --dart-define=CBIO_REVISION="$gs1_revision" \
      --dart-define=CBIO_APP_PACKAGE="$gs1_app_package" \
      --dart-define=CBIO_STREAM_SECONDS="$gs1_stream_seconds"
  ) >"$gs1_log" 2>&1
  gs1_status=$?
  set -e
  gs1_info "flutter test exit status: $gs1_status"
  gs1_info "device log kept at: $gs1_log"
fi

(
  cd "$gs1_repository_root/packages/cgm_cbio"
  dart run tool/record_gs1_evidence.dart --log "$gs1_log" --out "$gs1_evidence_dir"
)

gs1_info "evidence directory: $gs1_evidence_dir"
if [ "$gs1_status" -ne 0 ]; then
  printf 'error: the harness exited %s; the artifact above records what happened\n' "$gs1_status" >&2
  exit "$gs1_status"
fi
