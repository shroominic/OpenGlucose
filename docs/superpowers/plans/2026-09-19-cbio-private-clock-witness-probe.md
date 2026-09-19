# GS1 private clock-witness probe implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. The coordinator owns independent review; do not spawn another worker or execute on a phone without the coordinator's approval.

**Goal:** Distinguish mutable batch timestamp behavior from record changes during one bounded, private, authenticated session, without admitting or rewriting sensor history.

**Architecture:** A test/tool-only runner uses existing CBIO codecs, authentication builder and `BleSingleAttemptTransport`. A separate private Flutter entrypoint reads the saved sensor and raw-v1 envelope without initializing the production store/controller, executes the runner only with an explicit private enable flag, and emits a closed derived-only result. No production session, renderer, driver factory or core contract is changed.

**Tech Stack:** Dart, Flutter, `cgm_ble`, `cgm_ble_flutter`, `cgm_cbio`, existing native restricted files, fake BLE tests.

**Spec:** [Shared UI/private boundary](../specs/2026-09-19-cbio-shared-ui-restoration.md), plus the coordinator-approved bounded design recorded below. Design approval is not execution approval.

## Global constraints

- One exclusive physical connection to the already-saved sensor; no scan fallback, auto-reconnect, bond change, reset, activation, calibration, threshold or registration command.
- Production UI and all existing continuity/admission guards remain unchanged.
- Read existing files only; no `FileHealthStateStore.initialize`, app bootstrap, controller, adapter migration, checkpoint update or storage mutation.
- Use existing raw-v1 codec; preserve source bytes exactly. Unknown/malformed schemas, absent files and transaction artifacts abort without recovery.
- Protocol frames, identifiers, absolute times, readings and credentials remain memory-only. Do not use the old authenticated integration harness or its evidence runner: they print raw frames, and `flutter test -d` can uninstall app data.
- Limit normal clock writes to one attempt, including failed/unknown-outcome writes. Never retry a clock write.
- Standard discovered GATT model/software characteristics may be read, never guessed or written. Model strings stay memory-only; publish presence/format/equality-to-explicit-expected-value booleans only.
- No phone install, app launch, GATT session, signing-policy change, public artifact or PR change is authorized by this plan.

## Evidence and limits

At audit source `ac016e3`, `cbio_frames.dart:223,239` derives record `rawTime`
from one batch-header LE32 plus 60 seconds per record. The eight-byte record
contains temperature, dump, current and processed words; it has no independent
timestamp. `cbio_glucose_session.dart:413-433` writes the clock before querying
the saved checkpoint; `_writeClock` waits for ATT completion, not an opcode-03
response. H03B means the returned synthesized time differs, not that a physical
reset is established.

Raw-v1 persists `CgmReading`-encoded index/rawPayload and optional anchor-derived
recordedAt. Only its checkpoint stores one rawTime. Temperature/dump/processed,
reindex and original frames are absent. Do not invent these fields or compare
rawPayload alone as proof of record identity. This probe can compare full newly
observed records before/after clock sync; it cannot retroactively recover a
complete witness from v1. Exact clock-ACK result/status semantics are not yet
proven: a structurally matched ACK is not a claim that the clock was accepted.

## Ownership and files

Implement in new isolated worktree `worktrees/gs1-clock-witness-probe`, branch
`chore/gs1-clock-witness-probe`, from the reviewed boundary carrier. The temporary
lane does not create another issue/PR; accepted work stays under PR #209.

Create only:

- `openhealth/tool/cbio_probe/clock_witness_probe.dart`: fake-testable state machine and bounded in-memory comparisons.
- `openhealth/tool/cbio_probe/readonly_saved_state.dart`: schema-3 metadata/raw-v1 read-only file adapter.
- `openhealth/tool/cbio_clock_probe_main.dart`: private alternate Android entrypoint, privacy defaults, construction and derived summary.
- `openhealth/test/cbio_clock_witness_probe_test.dart`: fake transport, protocol, limits and redaction matrix.
- `openhealth/test/cbio_probe_saved_state_test.dart`: synthetic read-only file fixtures and byte preservation.
- `openhealth/test/cbio_probe_entrypoint_contract_test.dart`: source/entrypoint boundary and shipping exclusion checks.

Do not edit workers' package/session/controller/store/adapter files. Import the
reviewed package-exported raw-v1 codec after the host's tiny API commit; if that
commit has not landed, wait for that dependency rather than moving its codec in
parallel. Reuse the reviewed canonical identity encoder from the surface lane.

## Task 1: Read-only saved state

Interfaces to create:

```dart
final class CbioProbeSavedState {
  const CbioProbeSavedState({
    required this.sensor,
    required this.checkpoint,
    required this.envelopeBytes,
  });
  final DiscoveredSensor sensor;
  final CbioSessionCheckpoint checkpoint;
  final List<int> envelopeBytes;
}

Future<CbioProbeSavedState> readCbioProbeSavedState(Directory supportDirectory);
```

- [ ] RED: synthetic schema-3 metadata and raw-v1 blob resolve the exact saved driver/sensor; record all fixture bytes before/after and assert equality. Add unknown version, non-CBIO selection, foreign sensor, invalid checkpoint, absent canonical file, `.next`/`.previous`/`.deleted`, and symlink/path-escape rejection cases. Assert zero radio calls for every failure.
- [ ] Resolve only `OpenGlucose/RestrictedHealthState/restricted-health-state.json`, require integer schemaVersion 3 and string-valued `values`, parse `openHealth.lastSensor` using `DiscoveredSensor.fromJson`, and require driverId `cbio` with nonempty deviceId/storageKey. No fallback to preferences, archive display names or another sensor.
- [ ] Compute the unchanged raw-v1 key using the approved identity encoder. The existing native blob path is `HistoryBlobs/history-<sha256(utf8(key))>.blob`; the file contains raw envelope text, not another JSON wrapper. Validate it through the existing codec and decode its sensor-bound checkpoint. Reject transaction sidecars without renaming or deleting any file.
- [ ] Use only `exists`, `stat`, `resolveSymbolicLinks`, `readAsBytes` and in-memory decode. Require regular files beneath the resolved approved directory; reject oversized metadata/envelopes above 16 MiB each before allocation. Do not create directories or mark backup attributes.
- [ ] Run the tests RED, implement the reader, rerun GREEN and inspect that all fixture bytes remain unchanged.

Example assertion contract:

```dart
final before = await fixture.fileBytes();
final state = await readCbioProbeSavedState(fixture.supportDirectory);
expect(state.sensor.driverId, 'cbio');
expect(await fixture.fileBytes(), before);
expect(fixture.transport.connectCount, 0);
```

## Task 2: Bounded protocol state machine

Interfaces to create:

```dart
Future<Map<String, Object?>> runCbioClockWitnessProbe({
  required BleSingleAttemptTransport transport,
  required CbioProbeSavedState saved,
  required CbioCredentialSource credentials,
  required DateTime Function() clock,
  required String sourceRevision,
  bool includeAdjacentIndex = false,
});
```

The returned map is the closed public result, never an object containing frames.
Use a `Stopwatch`/deadline for duration; changing wall clock must not extend a
budget. Tests use `fake_async` or an injected private test scheduler to advance
timeouts without sleeping.

Validate `sourceRevision` against `^[0-9a-f]{40}$` before any BLE operation.
The private entrypoint supplies it from `CBIO_PROBE_SOURCE_REVISION`, an explicit
build define pinned by the reviewed build command, never a runtime guessed HEAD.

Exact schema: `schemaVersion` is 1; `sourceRevision` is a reviewed 40-character
lowercase hex commit; `outcome` is `completed`, `aborted` or `inconclusive`;
`reason` is one of `none`, `disabled`, `saved-state-invalid`,
`credentials-unavailable`, `single-attempt-unavailable`, `connect-failed`,
`topology-invalid`, `permission-unavailable`, `auth-failed`,
`preclock-unsupported`, `witness-missing`, `frame-invalid`, `phase-ambiguous`,
`ack-invalid`, `ack-timeout`, `write-outcome-unknown`, `limit-exceeded`,
`disconnected`, `cleanup-failed`, `storage-changed` or `internal-failure`.
`counts` permits integer `connect`, `authentication`, `clock`, `rawQuery`,
`frames`, `records`; `gattReleased` is boolean; `ack` permits only optional
uint8 `result`/`status` and boolean `structurallyMatched`.
`comparisons` permits only maps named `preRepeat`, `postRepeat`, `clockChange`,
`preAdjacent`, `postAdjacent`; each map permits integer `overlapCount`, optional
signed integer `constantTimeDeltaSeconds`, and booleans `fullRecordsEqual`,
`timeDeltaConstant`, `indicesMonotonic`, `reindexProgressionConsistent`.
`legacy` permits optional signed integer `preWitnessDeltaSeconds` and
`postWitnessDeltaSeconds`, boolean `weakPayloadEqual` and `bytesUnchanged`.
`deviceInformation` permits boolean `modelPresent`, `softwarePresent`,
`modelFormatValid`, `softwareFormatValid` and optional `modelExpectedMatch`,
`softwareExpectedMatch`. Omit unavailable comparisons rather than publishing
empty data as an equality result. Reject every other key, type or string.

- [ ] RED: missing credentials/invalid saved state/unsupported single-attempt transport makes zero connects; valid setup calls `connectOnce` exactly once, never scan/connect/bond APIs.
- [ ] Implement discovered FF31 notify/FF32 write characteristics, existing unmask/checksum/frame parsers and masked auth builder. Resolve auth address from discovered readable 2A25 exactly as the session does, or validated reverse MAC fallback; do not print either. One auth attempt, result 1 required, no retries. Reassembly must support fragments/multiple frames with the mask restarting per frame and reject invalid size/checksum without unbounded buffering.
- [ ] RED: repeated checkpoint-index query produces two independently delimited preclock samples; no clock is sent unless both contain the checkpoint and complete within budget. Missing witness, unsupported preclock read, malformed frame, disconnect or stream that never becomes idle terminates before the clock.
- [ ] Phase order: authenticate → checkpoint query A → checkpoint query B → optional preceding-index query → one clock attempt → structurally valid opcode-03 ACK → checkpoint query C → checkpoint query D → optional preceding-index query → disconnect. Adjacent index is `checkpoint.index - 1` only when index > 1; it is observation only and never passed through archive admission. No packed-0A, F0 information or other vendor commands are needed for this minimal probe.
- [ ] Each query is suffix-only on the wire: existing `buildMaskedCbioRawQuery(startIndex)` has no count argument. Capture only under the limits below; cap exhaustion aborts the entire run, not a silent truncation followed by another phase. Complete a phase only after the expected witness is present and one second of notification silence; an eight-second phase deadline without that silence is inconclusive/abort. Unexpected data between phases is ambiguous and aborts.
- [ ] Treat notification silence only as a bounded observational delimiter, never a protocol-level transaction guarantee. Frames carry no query ID: results must remain inconclusive if delayed packets cannot be distinguished from the current response. Do not use a passing fake schedule to claim physical attribution.
- [ ] Before clock invocation, arm its sole ACK waiter and record receive generation. Accept only a new post-invocation frame passing `parseCbioStartAckFrame(expectedOpcode: 0x03)` while the single clock operation is pending. Reject wrong opcode, old/duplicate ACK, invalid length/checksum, or timeout. Preserve result/status as bounded non-health integers in the derived result; do not translate them to a success state. Unknown ATT outcome also stops without retry, even if an ACK later appears.
- [ ] Compare newly observed overlapping same-index full four-word records in memory. Report equality booleans, overlap count, whether rawTime deltas are constant and the constant signed delta when they are. Report index ordering/gaps only as booleans/counts, not raw index lists. Reindex is allowed to change as the live suffix grows; compare its progression separately, not as immutable record identity.
- [ ] Compare old saved checkpoint time only as a signed delta to each newly observed witness; compare old rawPayload only as a clearly labeled weak diagnostic equality, never proof or admission. No reconstructed absolute timestamp is output.
- [ ] Finally cancel all subscriptions/timers, clear retained frame/record references and disconnect. Report failed cleanup truthfully. Delayed callbacks and timed-out pending operations must be unable to issue any later write. Dart GC does not guarantee secure erasure; claim only memory-only retention and explicit reference disposal.
- [ ] In the finalization path for every outcome, including aborted/error runs, reread and compare the same canonical metadata/envelope bytes whenever initial bytes were obtained. Any difference becomes `storage-changed`; unreadable comparison is explicitly failed verification, not equality. Do not restore, overwrite or merge either copy. This detects interference without modifying user state.

Hard ceilings (not caller-increasable):

- Session 120 seconds plus at most 10 seconds cleanup; connect 15 seconds, discovery 15 seconds, each GATT operation 8 seconds, auth/clock ACK 8 seconds.
- One connection, one authentication attempt, one clock attempt, four raw queries by default or six with explicitly enabled adjacent-index comparison: at most eight vendor writes total.
- At most 64 complete frames/512 records per query, 256 KiB retained frame/record bytes per session, and 256 bytes reassembly buffer per candidate frame. Exceeding any bound stops the run with a closed reason.
- Optional discovered readable 2A24/2A28 at most one read each; no characteristic guessing. Store results privately in memory; summary exposes only presence/format/expected-match booleans.

Required RED/GREEN matrix includes:

```dart
expect(fake.clockWrites, 0); // unsupported preclock or missing witness
expect(fake.clockWrites, 1); // valid probe, rejected ACK, unknown outcome
expect(fake.connectOnceCalls, 1);
expect(fake.scanCalls + fake.bondMutations + fake.otherVendorWrites, 0);
expect(fake.writesAfterTerminal, 0);
expect(savedBytesAfter, savedBytesBefore);
expect(summary.keys, everyElement(isIn(allowedSummaryKeys)));
```

Also cover: repeated preclock equal records/time; same records with constant
postclock time shift; changed payload/temperature/dump/processed; inconsistent
time deltas; nonmonotonic indices; adjacent batch origins; live suffix growth;
fragmented/coalesced frames; unsolicited/late/duplicate ACK; timeout at every
await; cleanup error; frame/byte/write caps; wall-clock jumps; identifiers,
secrets and payloads seeded with sentinel strings that must not occur in output.
Passing these tests proves harness behavior, not physical clock semantics.

## Task 3: Private entrypoint and offline verification

- [ ] RED: entrypoint imports only the probe/read-only adapter and required plugins, not `main.dart`, controller, driver factory, production session or writable store. Normal production main does not import the probe. Default `CBIO_PRIVATE_CLOCK_PROBE` false returns without reading saved state or touching BLE.
- [ ] Initialize Flutter binding only; suppress FlutterBluePlus logs before any BLE call using `disableFlutterBluePlusLogs`. Do not attach a raw trace sink. Construct `FlutterBluePlusTransport` with `showPowerAlert: false`, `restoreState: false`, and bounded operation/discovery durations. Do not run the normal app or request permission dialogs; missing already-granted permissions abort.
- [ ] Read the application-support directory through `path_provider`, call the read-only adapter, run the probe and print exactly one `CBIO-CLOCK-PROBE <closed-json>` line. Convert exceptions to closed reasons; do not print exception text/stack, paths, IDs, values or raw/plugin logs. A minimal private empty Flutter view may keep the engine alive; it is not production UI.
- [ ] Verify the closed result schema rejects arbitrary keys/strings and numeric lists. Allowed fields are schemaVersion, sourceRevision, outcome/closed reason, operation counts, cleanup status, ACK result/status, comparison counts/booleans/relative deltas and model/software evidence booleans. No absolute clock, identifier, raw word, reading, model string, checksum/hash of health data or credential is emitted.
- [ ] Execute from the isolated worktree's `openhealth` directory:

```sh
/Users/fungus/dev/openhealth/.toolchains/flutter/bin/flutter test --no-pub test/cbio_probe_saved_state_test.dart test/cbio_clock_witness_probe_test.dart test/cbio_probe_entrypoint_contract_test.dart --reporter expanded
/Users/fungus/dev/openhealth/.toolchains/flutter/bin/dart format --output=none --set-exit-if-changed tool/cbio_probe tool/cbio_clock_probe_main.dart test/cbio_probe_saved_state_test.dart test/cbio_clock_witness_probe_test.dart test/cbio_probe_entrypoint_contract_test.dart
/Users/fungus/dev/openhealth/.toolchains/flutter/bin/flutter analyze --no-pub
git diff --check
```

- [ ] Independent review checks protocol/write allowlist, ACK attribution limits, every timeout/cancellation path, absence of persistence writes and raw logging, normal artifact exclusion, and synthetic RED/GREEN evidence. Fix findings before artifact preparation.
- [ ] Build only after root supplies the existing private provisioning file and signing environment; do not print or recreate credentials. The command below uses already-set task-scoped `CBIO_PRIVATE_DEFINE_FILE` and `CBIO_PROBE_BUILD_NUMBER`; reject unset values before invoking Flutter. No install/run is implied:

```sh
: "${CBIO_PRIVATE_DEFINE_FILE:?existing private provisioning file required}"
: "${CBIO_PROBE_BUILD_NUMBER:?root assigned private build number required}"
: "${CBIO_PROBE_SOURCE_REVISION:?reviewed 40-character source revision required}"
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ANDROID_HOME=/Users/fungus/dev/.cbio-android-sdk ANDROID_SDK_ROOT=/Users/fungus/dev/.cbio-android-sdk LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 /Users/fungus/dev/openhealth/.toolchains/flutter/bin/flutter build apk --release --no-pub --target tool/cbio_clock_probe_main.dart --build-number "$CBIO_PROBE_BUILD_NUMBER" --dart-define=CBIO_PRIVATE_CLOCK_PROBE=true --dart-define=CBIO_PROBE_SOURCE_REVISION="$CBIO_PROBE_SOURCE_REVISION" --dart-define-from-file="$CBIO_PRIVATE_DEFINE_FILE"
```

## Separate physical authorization gate

Before root permits any installation/session, provide exact reviewed source
SHA, artifact hash, signer/package/version evidence, closed output schema,
offline results and the independently reviewed command sequence. Root verifies
the production app is disconnected and reserves sole radio ownership. A
same-package update must preserve data and signer; no uninstall, data clear or
profile switch. Preserve the previous reviewed normal artifact for restoration.
No `flutter test -d`, generic evidence runner or existing raw logger is allowed.

A normal clock write changes sensor state even in a diagnostic session. Root's
physical approval must explicitly include the one clock attempt, optional
adjacent-index reads and optional discovered GATT model/software reads. Abort
preclock if either baseline read is unsupported/inconclusive. After the probe,
verify byte preservation of the original restricted files and restore the
normal artifact through root's approved device lane without reconnecting unless
separately authorized.

## Interpretation and migration decision after evidence

Constant time shift with unchanged new full records supports frame-time rebasing
but does not independently prove historical era continuity. Unchanged time does
not prove a permanent firmware invariant. Variable shifts, record differences,
ambiguous late notifications or missing overlap yield inconclusive results.

Do not change witness admission based on this harness alone. Any future era
invariant must be sensor-bound and independent of mutable clock, with verified
record identity/rollover semantics. If immutable era evidence remains unknown,
keep segments separate and continuity unverified. Existing v1 bytes stay
unchanged. Any new durable full-record witness requires separately reviewed
additive versioned private storage; never populate missing legacy fields by
guessing, relabel raw glucose or discard old archives.
