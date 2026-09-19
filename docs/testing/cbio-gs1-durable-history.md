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

The private driver owner, not the shared host controller, saves and restores
this envelope. The selected-sensor pointer is not checkpoint authority. Private
checkpoint, clock and resume metadata is removed from public projections; the
driver rejects forged caller state. On reconnect, only the private envelope
checkpoint is authoritative. Existing and incoming rows merge inside the driver
only after exact restored input-checkpoint confirmation and re-reading the
matching witness. This proof is not public snapshot metadata. Merely having
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

An older app does not understand the new CBIO envelope key and cannot resume it.
Its old legacy-list data may be stale; do not treat an older app's display as the
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
  test/health_state_store_io_test.dart \
  test/home_archive_feedback_test.dart
```

Run `dart test` from `packages/cgm_cbio/` for private owner/session coverage.
Together these cover exact witness admission, era isolation, failed save/handoff
and retry, corrupt-target preparation, actual-driver/native-store restart,
interrupted rename/manifest migration and immutable legacy bytes. Shared UI
tests verify normalized fixtures and absence of raw/recovery presentation.
Physical-phone release validation remains a separate integration gate.
