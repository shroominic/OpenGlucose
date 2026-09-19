# CBIO durable raw history and recovery

CBIO history is diagnostic raw sensor data, not validated body glucose. This
storage change does not enable glucose alerts, treatment guidance, or wellness
analytics, and it does not establish sensor start/expiry from raw timestamps.

## Atomic complete-input state

The app implements optional `CbioFullRecordStore` with the new restricted key
`openHealth.history.cbio.fullRecords.v1.<identity>`, where `identity` is unpadded
base64url of JSON `[driverId, storageKey]`. It reuses the existing `.next`/
`.previous` native history-blob replacement, backup exclusion, rollback and
commit-only cache. Rows and current checkpoint are one atomic envelope, never
separate writes. A failed write leaves the prior complete envelope authoritative.

The internal closed schema binds version1, driver `cbio`, profile
`raw08-observed`, sensorKey, random128bit captureId and bootstrap provenance.
The captureId is an acquisition lineage, not a physical sensor-era identifier.
It cannot rotate or repair itself after counter/time conflicts.

- Pending has no rows or current checkpoint. Its bootstrap is either explicit
  fresh provenance or the exact original legacy checkpoint plus lowercase
  SHA256 of the original legacy UTF8 envelope, including whitespace.
- Observing contains the contiguous admitted prefix as seven-integer tuples
  `[index, rawTime, reindex, rawTemperature, rawDump, rawPayload, rawProcessed]`,
  its immutable first observation and matching final-row current checkpoint.
  First observation is fresh index1 or the exact admitted legacy witness.
  Reindex is response-relative: preserve its first observed value, not a later
  replay value. Index/time and the four raw words must match before duplicate
  suppression. RawTime is not reinterpreted as a wall-clock timestamp.

The original `openHealth.history.cbio.v1.<identity>` envelope/checkpoint remains
byte-for-byte frozen once the capability is selected. Its old CgmReading rows
lost temperature and other fields: never invent those fields, re-encode old
rows as complete, dual-write v1, or fall back to its writer on error. Legacy-only
custom stores retain the earlier incomplete compatibility path. Observing full
state is authoritative on restart; pending revalidates its exact legacy digest
and checkpoint (or absence for fresh). Malformed present full state fails closed.

The private driver owner, not the shared host controller, saves and restores
this envelope. The selected-sensor pointer is not checkpoint authority. Private
checkpoint, clock and resume metadata is removed from public projections; the
driver rejects forged caller state. On reconnect, only the private envelope
checkpoint is authoritative. Existing and incoming rows merge inside the driver
only after exact restored input-checkpoint confirmation and re-reading the
matching witness. This proof is not public snapshot metadata. Merely having
the same counter index, or a pending/failed/older producer, is insufficient.

Only a complete admitted contiguous candidate may advance the full checkpoint.
Existing time/witness/read guards remain unchanged; no automatic backfill is
added. Complete preservation does not establish decoder readiness.

Bounds are fixed at 65535 rows, 4194304 UTF8 envelope bytes and 4096 header bytes.
There is no truncation, eviction, cap increase or segment rollover. Exceeding a
bound fails before commit. A write failure pauses acquisition and polling and
retains the dirty candidate for explicit drain/retry; it never advances durable
progress. There is one live owner per store+binding and serialized writer, not a
cross-process lock. Close releases ownership only after successful drain.
Native string reads are not an OS pre-allocation memory guard. Atomic
primary/next/previous files can require 12 MiB plus frozen legacy; actual
device/storage headroom is UNKNOWN.

## One independent recovery capture

The app also implements optional `CbioRecoveryStore`. Its atomic
`openHealth.history.cbio.recovery.v1.<identity>` envelope selects one fresh
capture under the unchanged sensor binding. Schema1/profile `raw08-recovery`
records the closed reason `witness-time-mismatch`, exact UTF8 SHA256 references
to original fullRecords and nullable legacy strings, and one embedded fresh
full-record state. Predecessor strings remain solely at their original keys;
every load and selection checks their retained bytes. Neither original key is
rewritten by recovery. No predecessor rows/checkpoint/clock anchor are merged.

The unchanged exact witness-time guard first publishes its terminal failure.
The old notification and connection-state subscriptions must cancel and actual
GATT disconnect must finish successfully. The leased owner then drains private
writes, revalidates originals and absence of recovery, and atomically commits
the pending capsule before any successor radio connection. A separate session
uses fresh protocol state and raw index1; the original host-facing session
forwards its snapshots, logs and method calls. Close waits for transition and
cleanup to settle before releasing ownership. Closing before the next connect
prevents it; a committed pending selection remains selected across restart.

Capsule presence consumes the single budget, even while pending. Restart
resumes the same captureId and only its checkpoint, with exact witness matching.
Malformed presence, changed originals and a second mismatch stop without
another route or retry loop. Legacy/full-only stores retain their prior failure
behavior. Cleanup and storage failures forbid the successor and preserve the
original failure; a committed-but-reported-failed write is recognized on reload.

Fresh bounds remain 65535 rows, 4194304 UTF8 bytes and a 4096-byte header;
recovery metadata is bounded to 4096 bytes and the whole capsule to 4198400 bytes.
Overflow fails before writing, without truncation or rotation. Atomic files
need additional space alongside the immutable originals; device headroom is
unknown. Raw seven-field persistence still publishes no normalized glucose.
Every new session retains the existing clock write, so a later reconnect may
fail the exact witness guard again; the one-capsule budget is not replenished.

## Handoff and archives

A sensor switch prepares and validates the target read-only before rebinding
active state. The old immutable observed envelope must flush successfully; otherwise
the old identity, durable pointer, and unsaved in-memory suffix remain available
for retry. No new radio connection begins on a failed flush. Same-sensor retry
reloads the just-flushed checkpoint before committing its input state. The
existing controller assigns selected target IN MEMORY after drain. The new
session then commits pending adoption before BLE; no new pre-connect durable
selected-sensor write is introduced. Existing verified-identity durable
promotion remains later. A crash before promotion can leave an unused private
pending envelope; it never becomes another binding's bootstrap or observations.
Adoption re-reads storage after acquiring its lease so stale read-only preparation
cannot overwrite a newer revision.

Raw envelopes and legacy archive descriptors remain private. The adapter copies
original index/descriptors durably into
`openHealth.driverState.cbio.rawArchives.v1` before removing their public routes.
Original blobs and qualified legacy lists are preserved byte-for-byte, never
deleted or merged into a new raw era. Malformed or colliding state fails closed;
interrupted/repeated migration retries without discarding original data.

Shared history uses `openHealth.history.normalized.v1.<identity>`, not raw-v1.
Until a verified decoder exists, public latest/history/rawHistory remain empty,
normalized history counters zero/unknown and history capabilities false. Shared
AiDEX/Libre2 UI has no GS1 recovery/raw/export surface. Future verified normalized
records use the same history, lifecycle, chart and export policy as other sensors.
Preserving private raw bytes is not proof of decoded glucose or completed history.

## Rollback / downgrade

An older app may understand neither the fullRecords key nor the selected
recovery capsule and cannot safely resume that route.
Its frozen raw-v1 checkpoint and older legacy lists may be stale; do not treat
an older app's display as the
new history or allow it to overwrite the current state. Downgrading is not a
supported resume/recovery procedure. Keep a compatible build and the complete
restricted store when investigating recovery. No migration deletes legacy data.
Do not edit legacy archive descriptors or private manifests to force admission.

## Automated checks

Run from `openhealth/` with the pinned Flutter toolchain:

```
flutter test test/cbio_history_state_test.dart \
  test/app_controller_persistence_test.dart \
  test/cbio_real_session_controller_test.dart \
  test/cbio_private_state_adapter_test.dart \
  test/cbio_full_record_integration_test.dart \
  test/health_state_store_io_test.dart \
  test/home_archive_feedback_test.dart
```

Run `dart test` from `packages/cgm_cbio/` for private owner/session coverage.
Run `dart run -DCBIO_FAILURE_TRACE=true test/cbio_glucose_session_test.dart`
there as well to check the original failure is traced exactly once and successor
failures retain their own closed code. The successor suite covers two distinct
fake links, delayed/throwing cleanup, pending-before-connect ordering, close
races, stale callbacks, failed-close retry and restart budget retention. The
real app-controller/driver/adapter integration verifies that the first terminal
snapshot leaves existing subscriptions attached through fresh acquisition.
Together these cover exact witness admission, era isolation, failed save/handoff
and retry, corrupt-target preparation, actual-driver/native-store restart,
interrupted full-envelope rename/manifest migration, native backup exclusion,
immutable legacy bytes, pending-before-BLE, binding isolation and exact full-word
restart checkpoint authority. Shared UI
tests verify normalized fixtures and absence of raw/recovery presentation.
Physical-phone release validation remains a separate integration gate.
