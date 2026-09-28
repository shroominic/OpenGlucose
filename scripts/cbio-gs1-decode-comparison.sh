#!/bin/sh
# Replays one captured GS1 harness log as a durable side-by-side decode of the
# same records: the payload word the app's live path renders and the processed
# field the evidence path used to report.
#
#   make cbio-gs1-decode-comparison CBIO_EVIDENCE_LOG=<captured log>
#   CBIO_EVIDENCE_LOG=<log> make cbio-gs1-decode-comparison
#
# The log is the device log `make cbio-gs1-evidence` prints and keeps. This
# script never touches a device, a sensor, or a radio.
set -eu
umask 077

gs1_script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
gs1_repository_root=$(CDPATH='' cd -P "$gs1_script_dir/.." && pwd)
gs1_log=${CBIO_EVIDENCE_LOG:-}
gs1_evidence_dir=${EVIDENCE_DIR:-$gs1_repository_root/../evidence}

command -v dart >/dev/null 2>&1 ||
  {
    printf 'error: dart is not on PATH; run make bootstrap\n' >&2
    exit 1
  }

[ -n "$gs1_log" ] ||
  {
    printf 'error: CBIO_EVIDENCE_LOG=<captured log> is required\n' >&2
    exit 1
  }
[ -f "$gs1_log" ] ||
  {
    printf 'error: CBIO_EVIDENCE_LOG is not a readable file: %s\n' "$gs1_log" >&2
    exit 1
  }

(
  cd "$gs1_repository_root/packages/cgm_cbio"
  dart run tool/replay_gs1_decode.dart \
    --log "$gs1_log" \
    --out "$gs1_evidence_dir" \
    --source "make cbio-gs1-decode-comparison CBIO_EVIDENCE_LOG=$gs1_log"
)
