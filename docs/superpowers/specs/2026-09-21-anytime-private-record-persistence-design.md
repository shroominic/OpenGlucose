# Anytime private record persistence design

Status: proposed for `feature/anytime-5p` / PR106  
Date: 2026-09-21  
Risk class: R2 — health/device data and serialized local state

## Problem

`YuwellAnytimeSession` retains exact history records in `_recordByIndex` and
consumed record ordinals in `_observedRecordSlots`. Both collections exist only
for the lifetime of the Dart process. `_nextContiguousRecordIndex()` derives the
next request from that in-memory set, so a process restart discards exact record
bytes and all-FF empty-slot facts and restarts history paging at index zero.

The parser and paging loop already fail closed on out-of-range indexes,
unexpected frame starts, conflicting records, layout/opcode mismatch,
incomplete page budgets, and sentinel semantics. `0xFF` consumes an empty slot;
`0xFC` terminates without consuming a slot. This design persists those already
authenticated raw facts without creating a glucose decoder or a public data
path.

## Scope

This change will:

- persist one strict contiguous prefix of exact raw records and explicit all-FF
  empty slots;
- bind that prefix to the driver, one-way sensor storage binding, exact verified
  firmware, opaque history generation, opcode, and record layout;
- restore only matching, internally valid state before history paging;
- preserve the last durable prefix atomically and roll forward by re-fetching
  any uncommitted suffix;
- use the app's existing backup-excluded `HealthStateStore` history blobs; and
- prove package and app behavior with restart- and failure-focused tests.

This change will not:

- enable Anytime in the normal registry;
- add or alter a glucose decoder, `CgmReading`, dashboard, export, analytics, or
  public archive behavior;
- change pairing, activation, wire authentication, protocol commands, or normal
  device-write behavior solely to create persistence identity;
- add a database or rewrite the shared data layer;
- export raw private records; or
- claim physical durability until later device process-kill evidence exists.

## Durable identity

The raw envelope is accepted only when all of these values match the current
session:

1. `driverId == "yuwell-anytime"`;
2. `sensorBinding` is SHA-256 of the already one-way `DiscoveredSensor.storageKey`;
3. `historyGeneration` is a random opaque 128-bit local persistence-namespace
   token held only in secure credentials and copied to the raw envelope;
4. `firmware` is the exact verified firmware string, not inferred from
   `transmitterComputed`;
5. `historyOpcode` is the exact admitted history response opcode; and
6. `layout` is the exact `YuwellHistoryRecordLayout`.

The token is not sensor-emitted and is not evidence of a physical wear or
record era. Successful check-ID proves only that the saved communication
identity is currently accepted; existing source does not prove that reset,
replacement, or another lifecycle transition cannot retain or recreate the
same accepted identity. Restore therefore requires wire revalidation of the
entire durable prefix as described below.

The raw envelope does not contain the communication identity, sensor label,
credentials, calibration coefficients, activation time, or other low-entropy
identifiers.

`YuwellSessionCredentials` becomes additive schema v2 with nullable
`verifiedFirmware` and `historyGeneration`. New v2 credentials used for restore
must have both fields and pass strict validation. Schema v1 remains readable for
safe resume but never authorizes raw restore. A legacy credential may be
upgraded only after the existing connection has obtained an exact response from
the already documented read-only version command and completed the existing
authenticated check-ID path. Today the saved-session path skips that version
read and infers `V1150`; persistence-enabled sessions must instead issue the
same read-only version query already used by fresh sessions before `_resume`.
After the unchanged check-ID succeeds, the app atomically writes v2 with the
verified version and a new random token. The upgrade sends no
activation/configuration command, creates no write-intent entry, and does not
modify check-ID semantics. Thus existing v1 credentials become persistence
capable on their first successful authenticated resume rather than leaving the
optional store permanently dormant.

If that read-only version query fails, is unsupported, or returns a version the
driver does not admit, the session fails closed under the existing firmware
policy and does not restore or create raw state. Persistence never justifies a
state-changing write or relaxed authentication path.

The additive credential API is exact:

```dart
final class YuwellSessionCredentials {
  const YuwellSessionCredentials({
    // existing required fields unchanged
    String? verifiedFirmware,
    String? historyGeneration,
  });
  String? get verifiedFirmware;
  String? get historyGeneration;
  bool get canRestoreHistory;
  YuwellSessionCredentials copyWith({
    // existing parameters unchanged
    String? verifiedFirmware,
    String? historyGeneration,
  });
}

abstract interface class YuwellHistoryGenerationGenerator {
  String generate(); // 16 secure random bytes encoded as 32 lowercase hex
}
```

For schema v2 both identity fields are required and valid; partial identity is
rejected. `canRestoreHistory` is true only for such v2 material. The injected
generator defaults to a `Random.secure()` implementation and exists only for
deterministic tests; it has no decoder or wire-protocol role.

## Envelope and codec

`YuwellRecordState` is an immutable package model with schema version 1. Its
canonical JSON representation contains only:

- schema version and the six binding fields above;
- a `slots` array whose array offset is the sensor index;
- for a record slot, canonical base64 of exact 11-, 15-, or 17-byte record data;
- for an empty slot, an explicit enum value with no record data; and
- no timestamps, normalized values, parsed projections, or terminator entry.

Exact v1 bounds and grammar:

- encoded envelope: at most 524,288 UTF-8 bytes;
- slot count: 0 through 7,695;
- `driverId`: exactly `yuwell-anytime`;
- `sensorBinding`: exactly 64 lowercase hexadecimal SHA-256 characters;
- `historyGeneration`: exactly 32 lowercase hexadecimal characters encoding 16
  random bytes;
- `firmware`: 1 through 32 ASCII characters matching
  `[A-Z][A-Z0-9._-]{0,31}`;
- opcode: exactly `historyCommand` or `alternateHistoryCommand`, paired with an
  admitted layout;
- record bytes: exactly 11, 15, or 17 bytes as selected by layout; and
- sensor storage key accepted by store-key derivation: 1 through 128 UTF-8
  bytes and prefixed `yuwell:`.

Rules:

- slot count is 0 through 7,695 and therefore always represents indexes
  `0..length-1` with no gap;
- every record length matches the envelope layout and reparses through
  `YuwellHistoryRecord.parse`;
- every byte is 0 through 255 and neither `0xFC` nor `0xFF` sentinels can be a
  record slot;
- opcode and layout must be a supported pair;
- every string obeys the exact length/character grammar above;
- decoded JSON and encoded envelope bytes have fixed upper bounds;
- unknown keys, unknown schema versions, malformed base64, noncanonical base64,
  duplicates encoded through alternate shapes, and out-of-range state fail
  closed;
- adding an exact duplicate is idempotent;
- conflicting bytes, record-versus-empty conflicts, and noncontiguous additions
  fail closed; and
- `toString()` redacts bindings and contents.

The public package API is intentionally raw and private-state oriented. The
complete v1 signature surface is:

```dart
final class YuwellRecordBinding {
  const YuwellRecordBinding({
    required String sensorBinding,
    required String historyGeneration,
    required String firmware,
    required int historyOpcode,
    required YuwellHistoryRecordLayout layout,
  });
  String get driverId;
  String get sensorBinding;
  String get historyGeneration;
  String get firmware;
  int get historyOpcode;
  YuwellHistoryRecordLayout get layout;
}

sealed class YuwellRecordSlot {
  const YuwellRecordSlot();
}
final class YuwellRawRecordSlot extends YuwellRecordSlot {
  YuwellRawRecordSlot(Iterable<int> bytes);
  List<int> get bytes;
}
final class YuwellEmptyRecordSlot extends YuwellRecordSlot {
  const YuwellEmptyRecordSlot();
}

final class YuwellRecordBatch {
  YuwellRecordBatch({
    required int startIndex,
    required int consumedSlots,
    required Iterable<YuwellIndexedHistoryRecord> records,
  });
}

final class YuwellRecordState {
  factory YuwellRecordState.empty({required YuwellRecordBinding binding});
  factory YuwellRecordState.decode(String encoded);
  String encode();
  YuwellRecordBinding get binding;
  List<YuwellRecordSlot> get slots;
  int get nextIndex;
  void requireBinding(YuwellRecordBinding expected);
  YuwellRecordState appendBatch(YuwellRecordBatch batch);
}
```

Canonical JSON uses this exact key set and order:

```json
{"version":1,"driverId":"yuwell-anytime","sensorBinding":"<64 hex>","historyGeneration":"<32 hex>","firmware":"V1150","historyOpcode":69,"layout":"alert17","slots":[{"kind":"record","bytes":"<canonical base64>"},{"kind":"empty"}]}
```

`layout` is one of `compact11`, `voltage15`, or `alert17`; slot `kind` is
exactly `record` or `empty`. A record slot has exactly `kind` and `bytes`; an
empty slot has exactly `kind`. No alternate number/string coercions or extra
keys are accepted.

No method returns `CgmReading` or normalized glucose.

## Store and owner

The pure Dart package owns the persistence boundary:

```dart
final class YuwellRecordStoreKey {
  factory YuwellRecordStoreKey.forGeneration({
    required String sensorStorageKey,
    required String historyGeneration,
  });
  String get digest; // exactly 64 lowercase hexadecimal characters
}

abstract interface class YuwellRecordStore {
  Future<String?> read(YuwellRecordStoreKey key);
  Future<void> write(YuwellRecordStoreKey key, String envelope);
  Future<void> delete(YuwellRecordStoreKey key);
}

final class YuwellRecordStateOwner {
  static Future<YuwellRecordStateOwner> restore({
    required YuwellRecordStore store,
    required YuwellRecordStoreKey key,
    required YuwellRecordBinding binding,
  });
  YuwellRecordState get state;
  int get revision;
  int get durableRevision;
  bool get isDirty;
  Future<void> acceptBatch(YuwellRecordBatch batch);
  Future<void> completeHistoryCycle();
  Future<void> drain();
}
```

`YuwellRecordStateOwner` owns one binding and generation-aware store key. It:

- restores once and validates the complete envelope before exposing state;
- treats missing state as an empty prefix;
- rejects malformed or foreign state without partially loading it;
- accepts a complete parsed protocol frame as one in-memory batch;
- serializes writes behind one future tail;
- snapshots immutable state before each write;
- advances `durableRevision` only after the write completes;
- retains dirty state and the prior durable envelope if a write fails;
- surfaces the failure so the session stops acquisition rather than claiming a
  durable cursor;
- flushes after at least 16 newly consumed slots, after a larger completed
  frame, at history-cycle completion, and during explicit disconnect; and
- has an explicit `drain()` used by session close.

The 16-slot threshold bounds ordinary small-MTU write amplification. A sudden
process death can discard at most the uncommitted suffix. On restart the last
committed prefix is a quarantined candidate, not yet current sensor truth: the
driver re-reads from index zero, verifies every durable record/empty slot, and
then requests the suffix. Exact duplicate acceptance makes this roll-forward
safe.

## App adapter and composition

`YuwellHealthRecordStore` adapts `YuwellRecordStore` to the existing
`HealthStateStore`. Its logical key is:

`openHealth.history.yuwell.records.v1.<YuwellRecordStoreKey.digest>`

`YuwellRecordStoreKey.forGeneration` hashes these bytes in order: ASCII domain
tag `openhealth.yuwell.records.v1`, one zero byte, unsigned 16-bit big-endian
storage-key UTF-8 length, storage-key UTF-8 bytes, unsigned 16-bit big-endian
generation UTF-8 length, and generation UTF-8 bytes. The app uses its
64-character lowercase SHA-256 digest as `privateNamespace`; neither input
appears literally in the app key. A new history generation therefore selects a
new blob and leaves older generations untouched. Firmware/opcode/layout remain
authenticated envelope bindings inside that generation. They cannot be
silently overwritten: a mismatch fails closed.

`FileHealthStateStore` already routes every `openHealth.history.*` value to an
independent SHA-256-named blob, serializes mutations, replaces `.next` and
`.previous` atomically, and excludes the directory/files from backup. No shared
store migration is required.

`buildDefaultDriver` / `buildPlatformDriver` receive the initialized
`HealthStateStore` additively. Only the explicit Android Yuwell debug-capture
composition creates the adapter and passes it to `YuwellAnytimeDriver`. The
normal registry remains unchanged.

## Driver integration

The driver accepts an optional `YuwellRecordStore`. Absence preserves current
behavior. With a store:

1. establish or restore credentials using existing protocol rules; on a saved
   persistence-enabled session, issue the existing read-only version query
   before the unchanged authenticated check-ID;
2. upgrade v1 credentials only after check-ID, or require matching v2 durable
   identity with exact firmware and generation;
3. construct the binding from the authenticated session and selected opcode /
   layout;
4. decode the matching raw prefix into quarantined restored state;
5. start history sync at index zero and compare every returned record and FF
   slot against the quarantined prefix, rejecting an early FC terminator,
   missing slot, differing byte, or record/empty mismatch;
6. only after the complete prefix matches, rebuild `_recordByIndex` and
   `_observedRecordSlots`, trust its cursor, and continue at the first suffix
   index;
7. parse each incoming frame using existing strict parsing;
8. append its records and FF slots as one state transition before making the
   batch visible to the private cursor;
9. await required flush boundaries and fail the session closed on persistence
   failure; and
10. drain the owner before the BLE connection and session lease are released.

Restored records are not replayed through `_engineeringOutput`, snapshot
publication, normalized history, or live-overlap publication. Persistence is a
private acquisition checkpoint only.

Live notifications may legitimately arrive before history has filled the
prefix from zero. They therefore never call strict `appendBatch` and never
advance the durable history cursor. A valid live record at or beyond
`state.nextIndex` is held in an in-memory `_aheadLiveRecordByIndex` map bounded
to the protocol's 7,695 possible indexes;
an older live record must exactly match the restored/history record at that
index. When a history frame reaches buffered indexes, the driver builds a
candidate `YuwellRecordBatch`, reconciles every overlapping live record (exact
record match only; empty-versus-live or differing bytes is a conflict), and
asks the owner to accept the whole candidate before mutating
`_recordByIndex`, `_observedRecordSlots`, or removing covered ahead entries.
After acceptance, covered matching ahead entries drain into the private record
map and are removed from the ahead buffer. Live records beyond the newly
accepted prefix remain buffered. A failed owner acceptance leaves all driver
maps and the durable prefix unchanged and terminates acquisition. This
preserves the current ordering rule: only history responses consume slot
ordinals, while live notifications may be displayed by the already gated
engineering path without pretending to close history gaps.

## Failure, recovery, and roll-forward

- Missing envelope: start at zero.
- Malformed, future-schema, oversized, or foreign envelope: fail closed and
  preserve it; never delete or overwrite it automatically.
- Store read failure: fail the persistence-enabled session before paging.
- Matching envelope: re-fetch from zero and compare the complete durable prefix
  before it can advance the cursor. Check-ID and the local generation token do
  not waive this witness.
- Prefix mismatch, early FC, or missing slot: preserve the old envelope without
  write/delete, publish no restored data, and fail closed. Do not rotate the
  token or start a new era automatically.
- Store write failure: retain dirty in-process state, preserve the prior durable
  envelope, stop acquisition, and allow explicit drain/retry to surface failure.
- Crash between frames or before threshold: restart from the last durable prefix
  candidate, revalidate it from zero, and then re-fetch the suffix.
- Crash during atomic blob replacement: `FileHealthStateStore` restores the
  previously committed blob or the completed `.next` transaction using its
  existing rules.
- Credential generation changes: the generation-aware hashed key selects a new
  blob; old raw state remains untouched and cannot block or be overwritten by
  the new generation.
- Rollback to software without this feature: secure credential v2 must remain
  readable only if older code supports the version. Therefore schema v2 rollout
  is coordinated in the same delivery, and rollback validation includes
  returning to a build that safely rejects rather than corrupts v2. Raw blobs
  are additive and ignored by older builds.

There is no blank-state rewrite, slot deletion, prefix truncation, conflict
repair, or cross-generation merge path.

## Documentation and release gates

The delivery updates package README/changelog, compatibility documentation, and
adds ADR 0005 for the package/app persistence boundary and recovery contract.
Required automated gates are focused Dart format, analyze, package tests, app
adapter/composition tests, and the existing protocol-capture safety tests.

Because available disk is constrained, Android/iOS builds and physical
process-kill/restart evidence remain explicit later gates. Their absence means
the code can be review-ready but does not prove device durability or release
readiness.
