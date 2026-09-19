# Changelog

## 0.1.0

- Add optional opaque `CbioFullRecordStore` capability for complete private
  raw08 observations. Hosts implement atomic full-envelope reads/writes and
  SHA256 over the exact UTF8 legacy envelope. The app adapter uses the existing
  restricted history-blob store; original raw-v1 bytes/checkpoint are frozen.
  One pending/observing envelope preserves all seven observed integer fields
  and its authoritative current checkpoint under one acquisition captureId.
  Read-only preparation precedes old-owner drain and existing in-memory target
  selection; pending adoption must commit before BLE. No pre-connect durable
  selection write is added. Failed storage pauses acquisition without falling
  back or advancing durable progress; retries retain dirty state. Bounds are
  65535 rows, 4194304 UTF8 bytes and a 4096-byte header, with no truncation or
  rotation. Legacy-only hosts retain their incomplete compatibility path.
  Internal codec/owner remain unexported. No decoder, glucose, sensor-era,
  model/lifecycle or physical-device readiness is established.

- Add optional restricted private-state storage and read-only target preparation
  with durable handoff flushing. Raw-v1 archives retain their existing codec;
  failed writes stay dirty and retryable. Driver-owned raw acquisition and
  restored records no longer populate any public glucose reading field.
  Empty normalized output is an interim safety boundary, not verified glucose
  support. No decoder, clock protocol, activation or lifecycle claim is added.
  This supersedes the earlier host-owned persistence and public resume/support
  metadata entries below: raw acquisition/proof/clock state is private, public
  normalized history counters are zero/unknown, and decoded/raw history
  capabilities remain false. Generic stage and closed failure tokens remain;
  the app uses its shared sensor presentation without GS1 diagnostic UI.

- Distinguish the three existing counter-confirmation guards with a closed,
  ephemeral failure category for host support presentation. Caller metadata
  cannot provide the category; the failure gates, checkpoint format and
  transport behavior are unchanged. No record values or identifiers are added.

- Remove the default cumulative 480-read lifetime stop from production
  sessions. `CbioSessionTiming.maxReadsPerSession` is now nullable (null means
  unlimited); explicit finite bench caps still pause reads without declaring
  transport failure. `copyWith` retains a configured cap when omitted/null.
  Per-write and response deadlines remain bounded. Manual and automatic
  reads share a duration-timer cooldown; overlapping requests coalesce into
  one active operation and at most one pending earliest-cursor catch-up.
  Live cursors resolve when executed. Disconnect, counter-era failure, and
  late platform results cannot strand callers or restart polling.

- Publish explicit fresh/pending/confirmed/failed resume status and exact
  confirmed input-checkpoint binding for the host's durable merge boundary.
  Proof is emitted only after sensor witness matching, never copied from
  caller metadata, and absent after terminal failure.

- Add a versioned, sensor-bound resume checkpoint with counter-witness replay
  and validated clock-anchor provenance. Legacy offsets no longer skip history
  without evidence; malformed state, a missing witness, or a changed counter
  stops without appending a new era or clearing archived data. Preserve the
  last reconciled checkpoint and never advance it across a history gap.
  Hosts must atomically persist and restore the checkpoint with the archive;
  this package does not provide durable storage. Publish lifecycle as unknown
  until sensor-derived lifecycle evidence exists. Explicit disconnect retains
  validated snapshot state instead of restoring stale connection metadata;
  checkpoint anchors require explicit source provenance.

- Harden the authenticated session boundary: resolve the serial characteristic
  from its discovered service (including opaque iOS identifiers), release the
  GATT link on terminal topology/auth/write failures, surface history/live
  write failures as terminal states, and serialize overlapping reads so every
  caller settles without reviving a closed session.

- Add `CbioSessionEvidence`, `CbioSessionOutcome`, and `CbioWriteKind`: a pure,
  host-tested record of one device-backed session (outcome, classified write
  kinds, record counts and index ranges, bounded timing, closed error taxonomy,
  harness/app identity) whose `invariantViolations()` is the verdict a harness
  asserts. It cannot carry a sensor address, credential bytes, vendor material,
  or a physical glucose unit, and `unitStatus` stays `unverified`.

- Vendor link material (stream key, authentication material, prompt) is supplied
  by an injected `CbioCredentialSource`. Nothing is compiled into the package
  and no value is rendered in `toString`, a snapshot, or an exception.

- Add the vendor V120 read-query builders, a strict `0A` glucose batch decoder,
  and a bounded `CbioGlucoseSyncSession` for live polling and history paging
  with explicit fail-closed states. Records expose raw fields only and are
  never labelled with a unit.
- Add `inspectCbioReply`, a read-only structural inspection of one raw `FF31`
  notification. It reports the plaintext invariants, orientation and constant-mask
  searches, and returns `unresolved` with a null frame for the captured five-byte
  payload. It does not decrypt or reassemble.

## 0.0.1

- Reserve the `cbio` driver contract for offline GS1 research.
- Add app-derived `FF30` discovery candidates and `FF31`/`FF32` UUID constants.
- Keep all capabilities false and fail scan/connect without transport access.
- Add strict offline plaintext ACK and packed-record inspection, with synthetic
  integrity, bounds, bit-field, and counter tests. Raw fields have no assigned units.
- Add synthetic contract tests. No live protocol or glucose support is claimed.
- Add separate offline `08` raw-data, `F0/04` storage, and `F0/03` time parsers
  with exact frame bounds and synthetic rejection tests. Preserve the existing
  generic frame parser contract; no units, epoch, or sensor-state meaning is inferred.
- Add separate offline `F0/02` activation-state and expected `07`/`03` ACK
  inspection. Preserve all state/result bytes without granting write permission;
  test state/control separation and zero-history fields with synthetic fixtures.
