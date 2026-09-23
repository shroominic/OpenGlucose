# Anytime private record persistence implementation plan

> **For implementers:** REQUIRED SUB-SKILL: use `superpowers:executing-plans` to execute this plan task by task and `superpowers:test-driven-development` for every production change.

**Goal:** Preserve authenticated Anytime raw history slots across process death
without enabling normalized glucose, changing UI, or changing pairing and
activation behavior.

**Architecture:** Add a strict immutable raw-slot envelope and serialized owner
to the pure Dart vendor package, persist it through a thin adapter over the
existing atomic backup-excluded `HealthStateStore`, and restore it only when
secure credential schema v2 proves the exact selected storage binding,
firmware, local persistence namespace, and history layout. The random
generation is only a local namespace, not sensor-era proof. Recovery re-fetches
from index zero, verifies the complete durable prefix, and only then rolls
forward through the uncommitted suffix.

**Tech stack:** Dart 3.11, `package:test`, Flutter test, existing `crypto`,
existing `HealthStateStore`, Android Keystore bridge through the existing
`YuwellSecureSessionStore`.

**Spec:**
`docs/superpowers/specs/2026-09-21-anytime-private-record-persistence-design.md`

## Global constraints

- This is R2 health/device data plus serialized storage.
- Work only in `/Users/fungus/dev/openhealth/worktrees/anytime-5p` on local
  `feature/anytime-5p`. PR106's existing remote head is the legacy
  `feature/claude-anytime-5p` at `b8346ff`; preserve that PR and resolve its
  exact head before any separately authorized push. Do not create or rename a
  branch/PR.
- Do not add a dependency, database, decoder, speculative decoder API,
  normal-registry entry, UI, export, phone/radio action, or platform build.
- Do not change activation, pairing, authentication, or state-changing wire
  behavior solely for persistence. The existing read-only version command is
  allowed only as specified for exact firmware evidence.
- Persist only a contiguous history-confirmed prefix. Live records ahead of the
  prefix remain bounded in process and never advance the durable cursor.
- Keep the last durable blob immutable on malformed input or failed write; roll
  forward by revalidating the complete prefix from index zero and then
  refetching an uncommitted suffix.
- Never treat check-ID or the local generation token as immutable physical-wear
  proof. A prefix mismatch or early terminator preserves the old blob and fails
  closed without automatic generation rotation.
- Do not mutate driver record/slot maps until the owner accepts the complete
  history batch.
- Do not commit or push without separate authority.

---

## Task 1: Strict codec and serialized store owner

**Files:**

- Create: `packages/cgm_yuwell_anytime/lib/src/record_state.dart`
- Create: `packages/cgm_yuwell_anytime/lib/src/record_store.dart`
- Modify: `packages/cgm_yuwell_anytime/lib/cgm_yuwell_anytime.dart`
- Create: `packages/cgm_yuwell_anytime/test/record_state_test.dart`
- Create: `packages/cgm_yuwell_anytime/test/record_store_test.dart`
- Create: `docs/architecture/adr/0006-yuwell-private-record-persistence.md`
- Modify: `docs/architecture/adr/README.md`

### Step 1: RED — define the immutable envelope contract

First add only the complete public signatures from the spec with constructors
and methods that throw `UnimplementedError`, so the target compiles but has no
implemented behavior. Then write focused tests in `record_state_test.dart` for:

- empty bound state round trip;
- mixed exact record and explicit empty slot round trip;
- canonical contiguous index semantics (`nextIndex == slots.length`);
- exact duplicate batch idempotence;
- record-byte, record/empty, and binding conflicts rejected;
- gaps, negative indexes, indexes above 7694, and overflow rejected;
- opcode/layout mismatch rejected;
- record length mismatch, FC/FF record sentinels, malformed/noncanonical base64,
  extra JSON keys, unknown schema, oversized input, and malformed JSON rejected;
- foreign driver/sensor/firmware/generation/opcode/layout rejected by binding
  comparison;
- returned lists/bytes are immutable and `toString()` is redacted;
- the exact bounds are enforced: 524,288 encoded UTF-8 bytes, 7,695 slots,
  64 lowercase-hex sensor binding, 32 lowercase-hex generation, firmware
  `[A-Z][A-Z0-9._-]{0,31}`, and a 1..128-byte `yuwell:` storage key; and
- the library exposes no `CgmReading` conversion or normalized projection.

Use synthetic byte fixtures only. Before production code, state the mutation
that would make each test fail: changing a binding, slot kind, byte, index, or
schema must be detected by public behavior.

Run:

```bash
cd packages/cgm_yuwell_anytime
dart test test/record_state_test.dart
```

Expected RED: tests compile against the minimal interface and fail on the first
behavioral assertion because methods throw or return no implemented state. A
missing import/type compile failure is setup failure and must not be recorded as
RED.

### Step 2: GREEN — implement the minimal strict state model

Implement the exact signature surface in the spec:

- `YuwellRecordBinding` with driver ID, sensor binding, history generation,
  exact firmware, opcode, and layout;
- immutable sealed `YuwellRecordSlot` variants for raw bytes and empty FF slots;
- immutable `YuwellRecordState.empty`, `decode`, `encode`, `nextIndex`, binding
  validation, and `appendBatch`;
- schema version 1, maximum 7,695 slots, exact 524,288-byte envelope bound,
  exact binding/storage-key grammars above, canonical JSON keys, and canonical
  base64; and
- redacted `toString()` methods.

Reuse `YuwellHistoryRecord.parse` for record validation and existing command
constants for opcode/layout admission. Do not parse or persist normalized
glucose projections.

Export the new model from `cgm_yuwell_anytime.dart`, then run the focused test
until GREEN.

### Step 3: RED — define serialized owner behavior

Add the exact `YuwellRecordStoreKey`, `YuwellRecordStore`, and
`YuwellRecordStateOwner` signatures from the spec with unimplemented bodies.
Then write `record_store_test.dart` with a deterministic in-memory fake. Cover:

- missing value restores empty state;
- matching value restores its exact prefix;
- malformed/foreign value fails closed without write/delete;
- a complete batch is accepted as one state transition;
- writes are serialized even when futures complete out of order;
- flush occurs at 16 newly consumed slots, after a larger frame, at cycle
  completion, and on `drain()`;
- fewer than 16 slots can remain dirty until a boundary;
- write failure does not advance `durableRevision`, retains dirty state, does
  not delete/overwrite the fake's last durable value, and is surfaced;
- retry/drain can commit the exact pending state;
- an exact re-fetched suffix after simulated process death is idempotent;
- conflicting re-fetch is rejected; and
- generation-aware key derivation uses the specified domain tag and unsigned
  16-bit big-endian length framing, rejects out-of-bound storage keys, and gives
  distinct 64-lowercase-hex digests for distinct generations.

Run the focused test and verify behavioral RED against the unimplemented owner,
not a missing-type compile failure.

### Step 4: GREEN — implement the store boundary and owner

Implement in `record_store.dart` using the exact spec signatures:

```dart
abstract interface class YuwellRecordStore {
  Future<String?> read(YuwellRecordStoreKey key);
  Future<void> write(YuwellRecordStoreKey key, String envelope);
  Future<void> delete(YuwellRecordStoreKey key);
}
```

Add `YuwellRecordStateOwner.restore(...)`, `acceptBatch(...)`,
`completeHistoryCycle()`, and `drain()` with the exact signatures in the spec.
Use immutable
snapshots, `revision`/`durableRevision`, a serialized future tail, and the
16-slot policy in the design. Do not automatically delete invalid state or
invent conflict repair.

Run:

```bash
cd packages/cgm_yuwell_anytime
dart test test/record_state_test.dart test/record_store_test.dart
dart format --output=none --set-exit-if-changed lib test/record_state_test.dart test/record_store_test.dart
dart analyze
```

### Step 5: Document the R2 boundary

Write ADR 0006 with:

- decision and rejected alternatives (process memory, normalized repository,
  new database, credential payload containing all records);
- exact private binding and no-normalization rule;
- 16-slot/terminal/disconnect flush points;
- last-durable-prefix recovery and no destructive repair;
- complete wire revalidation of the durable prefix from index zero before
  cursor resume;
- v1/v2 credential rollout dependency; and
- rollback behavior.

Add it to the ADR index. Re-run focused tests after formatting.

**Task 1 review boundary:** codec and owner tests pass, but do not claim app
durability. The owner is not yet wired to credentials, the driver, or disk.

---

## Task 2: Secure identity, driver integration, and app composition

**Files:**

- Modify: `packages/cgm_yuwell_anytime/lib/src/session_security.dart`
- Modify: `packages/cgm_yuwell_anytime/lib/src/driver.dart`
- Modify: `packages/cgm_yuwell_anytime/test/session_security_test.dart`
- Modify: `packages/cgm_yuwell_anytime/test/yuwell_session_test.dart`
- Create: `openhealth/lib/src/yuwell_private_record_store.dart`
- Modify: `openhealth/lib/src/driver_factory.dart`
- Modify: `openhealth/lib/src/driver_factory_io.dart`
- Modify: `openhealth/lib/src/driver_factory_stub.dart`
- Modify: `openhealth/lib/main.dart`
- Create: `openhealth/test/yuwell_private_record_store_test.dart`
- Modify: `openhealth/test/yuwell_secure_session_store_test.dart`
- Modify: `openhealth/test/protocol_capture_safety_test.dart`
- Modify: `packages/cgm_yuwell_anytime/README.md`
- Modify: `packages/cgm_yuwell_anytime/CHANGELOG.md`
- Modify: `docs/compatibility.md`

### Step 1: RED/GREEN — additive secure credential identity

In `session_security_test.dart` and the app secure-store test, add RED cases:

- schema v1 restores with `verifiedFirmware == null` and
  `historyGeneration == null` and therefore `canRestoreHistory == false`;
- schema v2 exact round trip;
- v2 rejects missing/empty/oversized/malformed firmware or generation, unknown
  fields/version, and inconsistent partial identity;
- copy operations preserve identity unless explicitly upgraded;
- `toString()` remains redacted; and
- v1 records remain accepted by Android/macOS secure-store adapters without
  relaxing their encrypted-store requirements.

Implement the minimal v2 fields and strict reader. Keep v1 reader compatibility.
Generate a random opaque token through a small injected generator at the same
post-authentication point that persists verified credentials. For a
persistence-enabled saved session, issue the existing documented read-only
version command before `_resume`; after the unchanged authenticated check-ID
succeeds, upgrade v1 to v2 with that exact firmware and a new token. Assert that
this adds no activation/configuration write and no write-intent journal entry.
Do not add a state-changing wire write, pairing step, or authentication
shortcut. A failed/unsupported version response fails closed and never infers
`V1150` for persistence authority.

Run:

```bash
cd packages/cgm_yuwell_anytime
dart test test/session_security_test.dart
cd ../../openhealth
flutter test test/yuwell_secure_session_store_test.dart
```

### Step 2: RED — driver restart and failure behavior

Extend `yuwell_session_test.dart` using the existing fake transport and a
recording `YuwellRecordStore`. Add separate RED cases for:

- optional store absent preserves current session behavior;
- v1 credentials never read/restore a raw envelope;
- a persistence-enabled v1 saved session performs the existing read-only
  version query, then the existing authenticated check-ID, then atomically
  upgrades credentials and starts with an empty new-generation prefix;
- the legacy upgrade performs no state-changing command and creates no
  write-intent journal entry;
- v2 exact binding loads records and FF slots into quarantine; the first history
  request still starts at zero and the cursor advances past the durable prefix
  only after every slot matches;
- successful check-ID alone never authorizes cursor resume;
- an early FC, missing slot, differing byte, or record/empty mismatch preserves
  the old blob, performs no write/delete, publishes no restored data, and fails
  closed;
- foreign sensor/firmware/generation/opcode/layout and malformed state fail
  closed without protocol history publication;
- one frame containing records and FF slots reaches the owner atomically;
- an ahead-of-prefix live record is buffered without advancing the durable
  cursor or causing a gap failure;
- a later history frame drains an exact buffered live overlap only after owner
  acceptance, while differing bytes or empty-versus-live fails closed;
- owner rejection/write failure leaves `_recordByIndex`,
  `_observedRecordSlots`, and the ahead buffer unchanged;
- FC terminator is never persisted or counted;
- restored raw records never appear in snapshots, `CgmReading`, public history,
  engineering output, logs, or export-facing state;
- persistence write failure stops further history acquisition and preserves the
  previous durable prefix;
- simulated process death before the 16-slot flush revalidates the committed
  prefix from zero, then re-requests the uncommitted suffix and commits it
  without duplicates;
- history-cycle completion flushes; and
- explicit close awaits owner drain before disconnect and lease release.

Verify the focused test fails for the missing integration, not because the fake
protocol transcript is malformed.

### Step 3: GREEN — integrate private state into the driver

Add optional `YuwellRecordStore? recordStore` to `YuwellAnytimeDriver` and pass
it to the session. After existing authentication establishes v2 exact local
identity, create/restore the owner into quarantine. `_syncHistory` must begin at
zero, compare every history-confirmed record and FF slot to the complete durable
prefix, and reject early FC/missing/conflicting state without write/delete.
Only after the prefix matches may it rebuild `_recordByIndex` and
`_observedRecordSlots` and continue at the suffix cursor.

Refactor frame handling so one validated history frame first constructs a
candidate `YuwellRecordBatch` and reconciles any overlapping
`_aheadLiveRecordByIndex` entries. It then produces one owner `acceptBatch` call
before mutating `_recordByIndex`, `_observedRecordSlots`, or the ahead buffer.
Live records at/above the prefix remain bounded in the ahead map and never call
`appendBatch`; only history responses consume slot ordinals. After acceptance,
drain covered exact live entries into the record map and retain later entries.
Call the owner's flush boundary at history completion and drain it during
close. Convert store errors into a specific fail-closed session failure/log
code that contains no binding or payload.

Do not call `_engineeringOutput.observe...` for restored slots. Do not change
normal output policy, discovery, commands, write journal, activation, or the
normal registry.

Run the focused package tests until GREEN, then run the whole package suite:

```bash
cd packages/cgm_yuwell_anytime
dart test test/session_security_test.dart test/yuwell_session_test.dart
dart test
dart format --output=none --set-exit-if-changed lib test
dart analyze
```

### Step 4: RED/GREEN — app adapter and debug-only composition

Create tests for `YuwellHealthRecordStore` proving:

- it uses `YuwellRecordStoreKey.digest`, derived from the spec's domain-tagged
  unsigned-16-bit-length-framed sensor key and generation, as
  `openHealth.history.yuwell.records.v1.<digest>`;
- a new generation selects a distinct blob, leaves the old blob readable, and
  cannot overwrite or be blocked by the old envelope;
- read/write/delete delegate exactly once to `HealthStateStore`;
- no raw key, binding, record byte, or envelope content appears in `toString()`
  or error text; and
- a throwing health store propagates failure without delete or fallback.

Implement the adapter. Change `buildDefaultDriver` and platform factories to
accept the already initialized `HealthStateStore`. Pass it from `main.dart`.
Only `_buildCaptureRegistry`'s explicit Yuwell registration constructs the
adapter and supplies it to the driver. Stub/web and normal registry behavior
must remain unchanged.

Extend `protocol_capture_safety_test.dart` to prove Yuwell persistence remains
debug-capture-only and does not add a normal registration/output path.

Run:

```bash
cd openhealth
flutter test test/yuwell_private_record_store_test.dart test/protocol_capture_safety_test.dart test/yuwell_secure_session_store_test.dart
flutter analyze
```

### Step 5: Documentation and precise regression gates

Update package README/changelog and `docs/compatibility.md` with:

- private raw durability is additive and debug-capture-only;
- v1 credentials do not authorize restore;
- no normalized Anytime glucose support is enabled;
- recovery wire-validates the full durable prefix from zero before re-fetching
  the suffix; and
- physical restart proof remains pending.

Run final non-platform verification:

```bash
cd packages/cgm_yuwell_anytime
dart test
dart analyze
cd ../../openhealth
flutter test test/yuwell_private_record_store_test.dart test/yuwell_secure_session_store_test.dart test/protocol_capture_safety_test.dart test/health_state_store_io_test.dart
flutter analyze
git diff --check
git status --short
```

Record exact commands, exit codes, and source hashes. Do not run Android/iOS
builds while disk remains constrained. Do not claim release readiness, current
phone backup, physical persistence, normalized glucose, or UI acceptance.

**Task 2 review boundary:** code durability may be claimed only for the
tested package/app path after both deliveries pass. Device durability remains
unverified until a separately authorized physical process-kill/restart test.
