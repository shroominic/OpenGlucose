# CBIO durable raw history and recovery

CBIO history is diagnostic raw sensor data, not validated body glucose. This
storage change does not enable glucose alerts, treatment guidance, or wellness
analytics, and it does not establish sensor start/expiry from raw timestamps.

## Atomic state

The active restricted key is `openHealth.history.cbio.v1.<identity>`, where
`identity` is unpadded base64url of JSON `[driverId, storageKey]`. Its version-1
JSON envelope contains `schemaVersion`, `driverId`, `storageKey`, `checkpoint`,
and `history`. The checkpoint and raw rows are captured together before any
debounce/async boundary and replaced as one native history blob. Native storage
uses the existing `.next`/`.previous` atomic replacement, backup exclusion,
rollback, and commit-only cache. A failed write retains the prior complete pair.

The selected-sensor pointer is not checkpoint authority. Stale checkpoint,
clock, and resume-proof metadata is stripped from that pointer. On reconnect,
only the envelope checkpoint is supplied to the driver. Existing and incoming
rows can merge only when the driver publishes `confirmed` with the exact
restored input checkpoint after re-reading the matching witness. Merely having
the same counter index, or a pending/failed/older producer, is insufficient.

Live rows beyond a gap can be saved with an earlier safe witness while history
retrieval continues. Saved timestamps are not rewritten by replay. CBIO history
uses sensor-index order even when new rows have no wall-clock anchor.

## Handoff and archives

A sensor switch prepares and validates the target before rebinding active
state. The old immutable observed pair must then flush successfully; otherwise
the old identity, durable pointer, and unsaved in-memory suffix remain available
for retry. No new radio connection begins on a failed flush. Same-sensor retry
reloads the just-flushed checkpoint before committing its input state.

CBIO archives retain an envelope. Archive identity includes the checkpoint so
different counter eras sharing a display timestamp do not overwrite one another.

Legacy qualified list keys are never modified or merged into a new CBIO era.
They have a separate `cbio-unreconciled:` archive entry with `isUnreconciled`.
The UI labels these as history needing recovery, never as a successful empty
session. Readable legacy raw rows remain available for raw export with glucose
columns blank. Malformed original bytes remain in restricted storage with the
recovery entry; opening the entry is safe and offers no empty-success export.

## Rollback / downgrade

An older app does not understand the new CBIO envelope key and cannot resume it.
Its old legacy-list data may be stale; do not treat an older app's display as the
new history or allow it to overwrite the current state. Downgrading is not a
supported resume/recovery procedure. Keep a compatible build and the complete
restricted store when investigating recovery. No migration deletes legacy data.
If an older app rewrites an archive manifest without the new boolean, the
`cbio-unreconciled:` ID still preserves the recovery classification on upgrade.

## Automated checks

Run from `openhealth/` with the pinned Flutter toolchain:

```
flutter test test/cbio_history_state_test.dart \
  test/app_controller_persistence_test.dart \
  test/health_state_store_io_test.dart \
  test/home_archive_feedback_test.dart
```

These cover exact producer-proof admission, era isolation, failed save/handoff
and retry, corrupt-target prepare failure, native file restart and interrupted
rename recovery, immutable legacy data, and tapping a malformed recovery entry.
Physical-phone release validation remains a separate integration gate.
