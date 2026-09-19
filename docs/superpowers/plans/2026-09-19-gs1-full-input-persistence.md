# GS1 full-input preservation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline, task by task, with independent chief review after each task. No subagents are authorized. Steps use checkbox syntax for tracking.

**Goal:** Durably preserve complete observed raw08 input privately without rewriting legacy blobs or publishing glucose.

**Architecture:** Add an internal strict pending/observing envelope and one optional opaque storage capability. The driver-owned lifecycle adopts it only after selected-target commit and old-owner drain, then atomically stores admitted records with their current checkpoint. The existing restricted app adapter implements the optional capability; no core/UI protocol expands.

**Tech Stack:** Existing Dart3.11.4/Flutter3.41.6, cgm_cbio, cgm_ble fakes, restricted HealthStateStore and existing app crypto dependency.

**Spec:** `docs/superpowers/specs/2026-09-19-gs1-full-input-persistence.md`

## Global constraints

- Base8733e96; isolated fix/gs1-full-input-persistence; existing PR209 only.
- RiskR2, owner@shroominic; independent chief review for each task.
- No public normalized/raw output, UI/core/probe/newBLE/native changes.
- No new dependencies, frameworks, builds, phone/radio, publication or subagents.
- Fixed65535rows/4194304UTF8bytes/4096headerbytes; no silent truncation or raised existing budgets.
- prepareTarget read-only. Adoption after old-owner drain and target commit, before BLE.
- Frozen originalv1 bytes. One atomic full envelope with its current checkpoint.
- No counter-era inference, loosening witness/time guards or synthesized missing fields.
- Full envelope and owner types remain package-internal and unexported.
- Decoder readiness unavailable. Device/storage headroom unknown.

## Commands and evidence

Use `/Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart` and sibling
`flutter`. Run every command in this worktree. Package commands run under
`packages/cgm_cbio`; app commands under `openhealth`. Restore package dependencies
with `dart pub get --offline`, app with `flutter pub get --offline --enforce-lockfile`.
No committed lockfile drift is allowed. Logs go to private `/tmp/cbio-full-input-*`.
Baseline package suite must pass before code. Final offline package/app suites,
scoped format/analyze and git diff --check must pass; explicitly exclude builds.

## File and interface map

- NEW `packages/cgm_cbio/lib/src/cbio_full_record_state.dart`: strict immutable
  codec; consumes CbioRawGlucoseRecord and CbioSessionCheckpoint. No BLE/store.
- NEW `packages/cgm_cbio/lib/src/cbio_full_record_owner.dart`: private read-only
  load, pending adoption, single-writer lease, admitted immutable-word merge,
  checkpoint durability and drain/close. Uses optional opaque store only.
- MODIFY `packages/cgm_cbio/lib/src/cbio_private_state.dart`: add the following
  additive capability beside unchanged old CbioPrivateStateStore:

```dart
abstract interface class CbioFullRecordStore implements CbioPrivateStateStore {
  Future<String?> readFullRecords(String sensorKey);
  Future<void> writeFullRecords(String sensorKey, String envelope);
  String legacySha256(String legacyEnvelope);
}
```

The hash function is a narrow host service over an already opaque legacy string;
the app uses its EXISTING crypto dependency. This avoids introducing a package
runtime dependency or hand-written cryptography. Require lowercase64hex output.
Package tests use deterministic predeclared synthetic legacy/digest fixtures;
adapter integration checks real SHA256 known vectors and exact legacy bytes.
The existing exported cbio_private_state.dart already exposes opaque storage;
no new raw-record/codec export is added.

## Task1: Strict internal full-record codec

**Files:**
- Create `packages/cgm_cbio/lib/src/cbio_full_record_state.dart`
- Create `packages/cgm_cbio/test/cbio_full_record_state_test.dart`

**Interfaces produced:**

```dart
final class CbioFullRecordState {
  static const maxRows = 65535;
  static const maxBytes = 4194304;
  static const maxHeaderBytes = 4096;
  factory CbioFullRecordState.pending({
    required String sensorKey, required String captureId,
    String? legacyDigest, String? bootstrapCheckpoint,
  });
  factory CbioFullRecordState.decode(String value, {required String sensorKey});
  CbioFullRecordState observing({
    required List<CbioRawGlucoseRecord> records,
    required String currentCheckpoint,
  });
  String encode();
  // Immutable fields: sensorKey,captureId,legacyDigest,bootstrapCheckpoint,
  // currentCheckpoint,records; bool isPending; String? resumeCheckpoint.
}
```

- [ ] Write a failing literal seven-word roundtrip test. A compile stub may be
  added solely to obtain an assertion failure before behavior implementation.

```dart
final state = CbioFullRecordState.pending(
  sensorKey: 'synthetic', captureId: '0123456789abcdef0123456789abcdef',
).observing(records: [
  const CbioRawGlucoseRecord(index: 1, rawTime: 120, reindex: 9,
    rawTemperature: 321, rawDump: 7, rawPayload: 432, rawProcessed: 5),
], currentCheckpoint:
  '{"version":1,"sensorKey":"synthetic","index":1,"rawTime":120}');
final restored = CbioFullRecordState.decode(state.encode(), sensorKey: 'synthetic');
expect(restored.records.single.rawTemperature, 321);
expect(restored.records.single.rawDump, 7);
expect(restored.records.single.rawProcessed, 5);
```

- [ ] Run `dart test test/cbio_full_record_state_test.dart --reporter expanded`;
  save RED log showing missing preservation, not a typo.
- [ ] Implement minimal immutable field codec, closed schema/profile/state keys,
  tuple validation and canonical JSON. Pending has no current checkpoint/rows;
  observing checkpoint must match final row and existing checkpoint parser.
- [ ] Add individual failing cases before each validation: foreign binding,
  unsupported/extra/missing fields, invalid captureId/hash, bootstrap pair
  mismatch, non-int/bounds, duplicate/out-of-order/gapped rows, first row not
  bootstrap witness or freshindex1, checkpoint not final exact row, invalid
  anchor, mutable input list, oversize header/input and maxdomain boundaries.
  Implement each guard only after its failure. No health fixtures.
- [ ] Run focused suite GREEN and all package tests; run scoped dart format and
  dart analyze --fatal-infos, then git diff --check.
- [ ] Commit only codec/test files as `fix: preserve complete GS1 input envelopes`;
  send exact SHA and RED/GREEN logs to chief; hold task2 for review approval.

## Task2: Driver-owned adoption, record admission and restart checkpoint

**Files:**
- Create `packages/cgm_cbio/lib/src/cbio_full_record_owner.dart`
- Create `packages/cgm_cbio/test/cbio_full_record_owner_test.dart`
- Modify `packages/cgm_cbio/lib/src/cbio_private_state.dart`
- Modify `packages/cgm_cbio/lib/src/cbio_private_state_owner.dart`
- Modify `packages/cgm_cbio/lib/src/cbio_driver.dart`
- Modify `packages/cgm_cbio/lib/src/cbio_glucose_session.dart`
- Modify `packages/cgm_cbio/test/cbio_glucose_session_test.dart`
- Modify `packages/cgm_cbio/test/cbio_driver_test.dart`
- Modify `packages/cgm_cbio/test/cbio_private_state_test.dart`

**Consumes:** task1 codec + existing private state, parser, checkpoint and BLE.
**Produces:** internal full owner with these methods:

```dart
static Future<CbioFullRecordOwner> load(String sensorKey, CbioFullRecordStore store);
Future<void> adopt(); // acquire exclusive store+binding lease; durable pending
String? get resumeCheckpoint; // last DURABLE current, otherwise bootstrap
void accept(List<CbioRawGlucoseRecord> records, {
  required String admittedInputCheckpoint, // empty only for fresh
  required String currentCheckpoint,
});
Future<void> flush();
Future<void> close(); // drains first, releases lease only on successful drain
```

Implementation can keep a package-internal candidate/observation check method
for pre-dedup validation; it must never be exported. The existing private owner
delegates to full owner only when the store implements CbioFullRecordStore;
its legacy state stays available solely for frozen bootstrap validation. Default
memory/old custom stores keep their prior path and tests, without false full-input
durability claims. prepareTarget calls read-only load, never adopt/lease.

- [ ] Write failing owner adoption test using real owner/codec and synthetic
  in-memory store; asserting persisted bytes, not a mocked owner:

```dart
final owner = await CbioFullRecordOwner.load('synthetic', store);
expect(store.fullEnvelope, isNull); // read-only load
await owner.adopt();
expect(CbioFullRecordState.decode(store.fullEnvelope!, sensorKey: 'synthetic').isPending, isTrue);
expect(store.legacyEnvelope, originalLegacyBytes);
```

- [ ] Run focused RED; implement read-only loading and exact digest/checkpoint
  validation, secure random captureId creation on first adoption, single-writer
  store+binding lease and atomic pending write before BLE initialization.
- [ ] Write failing owner admission/restart tests with two differing temperatures,
  exact current checkpoint and constant oldv1 bytes. Enforce same immutable
  lineage, first row/bootstrap provenance, identical-word duplicate equality,
  response-relative reindex retention, bounded merged rows and existing witnesses.
- [ ] Write delayed/failing-store tests: second writer refused, failedpending
  opens zero BLE connections, candidate durable checkpoint unchanged until write
  completes, error retains dirty candidate, close failure retains lease, drain
  then reconnect loads new checkpoint, malformed present state never falls back.
- [ ] Write failing real-session tests showing altered-temperature duplicates
  cannot bypass archive dedup, resumed witness words must match, current checkpoint
  survives restart, no oldv1 writes, and public snapshots remain null/empty.
- [ ] Implement session integration: parse full incoming records after existing
  auth/witness gates, check retained full words before archive duplicate path,
  persist only admitted contiguous candidates. Pause timers/read scheduling on
  persistence error without expanding BLE command set. Drain/release full owner
  after disconnect even if best-effort BLE cleanup fails.
- [ ] Keep driver prepareTarget read-only. Its connect waits prior drain/close,
  reloads selected binding, then new session adopts before transport.connect.
  Host-selected identity is already committed before driver.connect; task3 verifies
  that ordering without altering controller behavior.
- [ ] Run new/focused tests GREEN and whole package suite, scoped format/analyze,
  diffcheck. Commit task2 files as `fix: atomically persist admitted GS1 inputs`;
  send exact SHA and logs to chief and await review before task3.

## Task3: Restricted adapter and app handoff integration

**Files:**
- Modify `openhealth/lib/src/persistence/cbio_private_state_adapter.dart`
- Modify `openhealth/test/cbio_private_state_adapter_test.dart`
- Modify `openhealth/test/app_controller_persistence_test.dart`
- Modify `openhealth/test/sensor_connection_flow_test.dart`
- Modify `packages/cgm_cbio/CHANGELOG.md`
- Modify `docs/compatibility.md`
- Modify `docs/testing/cbio-gs1-durable-history.md`

**Consumes:** task2 additive opaque interface, existing encoded sensor identity,
HealthStateStore per-history atomic replacement, current controller handoff.
**Produces:** CbioPrivateStateAdapter implements CbioFullRecordStore with fixed
new key, no public archive registration, and SHA256 using existing app crypto.

- [ ] Write RED adapter tests before methods: exact sensor-bound key routing,
  identicalv1/normalized/public-index bytes across full writes, standardSHA256
  vector (empty input digest literal), foreign binding separation and malformed
  new state preserved rather than falling back.
- [ ] Implement only readFullRecords/writeFullRecords/legacySha256. Reuse exact
  binding encoder; no new store or file-level transaction. Example assertions:

```dart
await adapter.writeFullRecords('synthetic', validPendingEnvelope);
expect(await adapter.read('synthetic'), originalLegacyBytes);
expect(await adapter.readFullRecords('synthetic'), validPendingEnvelope);
expect(adapter.legacySha256(''),
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
```

- [ ] Add integration tests using real driver/private adapter and delayed store:
  prepareTarget does zero writes, failed old drain or selected-target commit
  creates no pendingnewblob and no BLE, successful target commit precedes pending
  and pending precedes BLE, restart selects new full checkpoint, originalv1 bytes
  stay exact after successful/failed writes. Preserve existing controller ordering.
- [ ] Cover actual restricted-file adapter where available: single envelope old
  or new after simulated interrupted replace; no checkpoint/row mixed state;
  existing backup-exclusion behavior reused. No phone tests.
- [ ] Update compatibility/changelog/recovery docs: additive optional storage API,
  legacy frozen/incomplete, one capture lineage, malformed-state fail closed,
  no downgrade recovery, new namespace/caps, no calibrated-glucose support.
- [ ] Run full package `dart test` and app `flutter test --no-pub`, record exact
  counts. Run app `flutter analyze --no-pub --fatal-infos`, package analyzer and
  relevant dartformat/diffcheck. No builds/makecheck's platform lanes.
- [ ] Commit as `fix: integrate restricted GS1 full-input storage`; send chief
  exact final source and evidence, leave branch unpublished for root integration.

## Self-review

Spec coverage: pending/observing/bounds in task1; adoption/checkpoint/identity/
pre-dedup/failure/restart in task2; targetcommit ordering/namespace/legacy privacy/
compatibility in task3. No sensor-era recovery or decoder is introduced. Interface
names above are authoritative for all tasks. User's inline/no-subagent execution
choice is already explicit; do not ask again. Stop for chief's plan review BEFORE
task1 code and at each commit boundary. No completion claim before final evidence.
