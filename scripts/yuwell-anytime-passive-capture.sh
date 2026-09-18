#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
OPENGLUCOSE_CAPTURE_PROFILE=yuwell_anytime_passive
export OPENGLUCOSE_CAPTURE_PROFILE

exec "$script_directory/libre-protocol-capture.sh" "$@"
