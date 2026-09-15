# Recorder-free Libre Gen1 receiver boundary

Status: native and Dart components now compose into an explicitly opted-in
Android debug validation path. The default application and every release build
still omit this receiver. No receiver was enrolled, transferred, reset, or
tested on hardware for this slice. This is part of the remaining
[production integration](libre2-production-integration.md), not a release claim.
Owner: `@shroominic`. Risk: R2 implementation; production distribution remains R3.

## Scope

`LibreGen1ReceiverCoordinator` reuses the existing encrypted
`LibreGen1StreamingStore` and durable journal. It permits restricted inspection
of an existing confirmed receiver and leases that exact receiver before BLE
connection. It cannot prepare or abort enrollment, activate the sensor, enable
streaming, clear state, delete bonds, or replace a receiver. Prepared, unknown,
corrupt, unreadable, and unsupported records are not treated as an absent sensor.
Only a positively absent store returns a null bootstrap.

The Android bridge has a separate `com.openglucose/libre2_receiver` channel.
Native composition keeps its exclusivity guard true only while the debug
recorder backend is excluded. A query does not grant ownership. There is no new
support flag or automatic fallback from the read-only or private capture channels.

## Private validation composition

The existing `openGlucoseLibreNfcReadOnly=true` native selector remains default
off. With that selector, `MainActivity` registers the existing read-only NFC
bridge. It additionally registers the separate receiver bridge **only when the
application is debuggable**. The native guard requires the selected read-only
backend to remain registered and the recorder to remain absent. Detach/destroy
revokes methods and retains unresolved ownership; it does not assert BLE close.

| Native selection | Dart selection | Result |
| --- | --- | --- |
| Default | Normal main | Existing AiDEX-only registry |
| Read-only opt-in, release/profile | Normal main | Read-only NFC only; no Libre BLE receiver |
| Read-only opt-in, Android debug | Normal main, no trace/demo | Strict receiver capability probe; saved receiver plus AiDEX if available |
| Read-only opt-in, Android debug | Existing private glucose entry, no trace/demo | Explicit saved-receiver decoder and NFC history integration; missing receiver capability fails startup |
| Default, Android debug | Existing private trace flags | Existing private capture path, unchanged |
| Read-only opt-in | Private trace flags | Capture bridge is absent; capture startup fails without fallback |

Before registry construction, `LibreGen1ReceiverComposition` checks the exact
five-field capability with a three-second deadline. Missing, malformed, failed,
or late replies leave AiDEX available. A successful probe does not read a
bootstrap, acquire a lease, or connect. BLE plugin logs are disabled before this
recorder-free composition performs any radio work. The shared registry retains
one scanner, the exact stored Libre classifier, and `externalSetupOnly` policy.
The Libre driver alone receives `LibreGen1ReceiverTransport`; AiDEX keeps its
existing transport and policy.

App bootstrap initializes one restricted history repository, then passes its
observation adapter to platform history setup before building the controller's
driver. Both private Libre paths require this same durable owner. Receiver
probing and log suppression occur before publication of the recorder-free
composition; there is no volatile fallback. The decoder-free receiver still
commits CRC-validated observed minutes even when it has no glucose conversion.
See [ADR 0006](../architecture/adr/0006-atomic-libre-observations.md) for atomic
history, deletion, restart, migration, and uncertainty rules.

Saved-receiver availability is separate from NFC streaming setup availability.
The existing saved sensor card can read the protected bootstrap and offer an
explicit Connect. That action still requires a fresh matching advertisement,
native ownership, and a reserved counter. The read-only NFC capability remains
unchanged with `receiverAvailable`, `streamingAvailable`, and
`activationAvailable` false. It supplies no enrollment proof. The generic NFC
reader still refuses existing receiver/private operation state; adding the
receiver channel does not weaken that rule. The separate saved-receiver
history route below requires the exact confirmed journal owner instead.

Normal-main validation injects **no glucose decoder** and imports no GPL adapter.
It can validate receiver login and packet handling, not calibrated glucose.
There is no new enrollment, activation, streaming-enable, credential migration,
reset, or capture-file fallback. Unknown/legacy leases still block acquisition,
and a missing receiver must be reported as absent rather than enrolled.

The existing `libre_glucose_debug_main.dart` entry can instead inject the private
decoder through `LibreGen1ReceiverStore.readCalibrationEvidence`, with the same
native read-only selector and no trace/demo flags. This mode requires receiver
capability; a missing, malformed, failed, or late reply stops startup rather than
silently omitting the requested receiver. Configuration must precede driver
construction. The normal main remains decoder-free. This does not change the
[private decoder distribution gate](../architecture/adr/0004-private-libre-glucose-decoder.md).

## Saved-receiver NFC history

This is a separate purpose on the receiver channel, not a relaxation of generic
setup. The explicit settings history action first closes the selected BLE
connection and background target. Only then can the exact saved receiver acquire
the shared RF lease. Unknown, partial, legacy, or still-held leases remain
blockers; historical capture files and receiver journal bytes are not changed.

| Method | Exact arguments | Result |
| --- | --- | --- |
| `historyCapabilities` | Empty map | Exactly `schemaVersion: 1`, `backend: receiverHistory`, `readAvailable: bool`, and `activationAvailable`, `streamingAvailable`, `receiverAvailable`, `rawCapture` all false |
| `startLibreGen1HistoryRead` | `attemptId`, `bootstrapId` | `null` after attempt admission; no enrollment or BLE counter authority |
| `stopLibreGen1HistoryRead` | `attemptId`, `bootstrapId` | `null` only after exact attempt cleanup; successful completed-read evidence remains briefly available |
| `readLibreGen1FreshHistoryEvidence` | `attemptId`, `bootstrapId` | One-use restricted evidence map after confirmed cleanup and exact receiver revalidation |
| `discardLibreGen1FreshHistoryEvidence` | `attemptId`, `bootstrapId` | Memory-only evidence revocation; this does not prove RF cleanup |

Events use `com.openglucose/libre2_receiver_history_events`. Their closed
attempt/status/model shape contains no sensor ID, protocol bytes, or readings.
The read uses the existing 16 fixed commands and three-region CRC checks. It
matches the exact UID and model prefix but uses the patch seed from this read
for FRAM decoding; the frozen Bluetooth patch remains a separate credential.
It does not activate, enable streaming, replace factory evidence, or reserve a
Bluetooth login count.

Fresh evidence has exactly seven fields: `attemptId`, `bootstrapId`, `uid`,
`receiverInitialPatchInfo`, `currentPatchInfo`, `encryptedFram`, and
`observedAtUtc`. Delivery requires confirmed transport close, reader stop,
exact lease release, and an unchanged full journal binding. Its lifetime is
bounded by both wall and monotonic clocks, at most 120 seconds. A successful
stop preserves it only for the one-use decoder handoff. Cancellation/disposal
discards it explicitly; native lifecycle loss, replacement, and expiry also
revoke it. Local Dart revocation alone is not proof of native buffer cleanup.

Each history sync owns one platform/session. Cancellation still requires exact
stop even if a capability probe or start reply arrives late. Uncertain cleanup
keeps the controller read scope blocked. A successful read uses the existing
atomic history importer and refreshes saved data without making an old sample
current. Resuming BLE is explicit. Terminal/expired ring timing, physical NFC
backfill, and release qualification remain open; this path does not change
their evidence requirements.

## Closed method contract

| Method | Exact arguments | Result |
| --- | --- | --- |
| `capabilities` | Empty map | Exactly `schemaVersion: 1`, `backend: receiver`, `restoreAvailable: bool`, `enrollmentAvailable: false`, `rawCapture: false` |
| `readLibreGen1StreamingBootstrap` | `null` | Existing six-field restricted bootstrap map, or null on positive absence |
| `readLibreGen1CalibrationEvidence` | `bootstrapId` | Existing five-field restricted evidence map or null; protected cache only, no capture-file fallback |
| `acquireLibreGen1Receiver` | `sessionId`, `bootstrapId` | Opaque `leaseToken` |
| `reserveLibreGen1UnlockCount` | `sessionId`, `bootstrapId`, `leaseToken` | Durably reserved integer counter |
| `markLibreGen1LoginOutcome` | Ownership fields plus `unlockCount`, `outcome` | `null`; outcome is only `unknown` or `acknowledged` |
| `releaseLibreGen1Receiver` | Ownership fields plus boolean `transportClosed` | `null` only after exact-owner cleanup; `transportClosed` must be true |

Tokens are bounded ASCII identifiers. Additional keys and wrong argument types
are rejected. The bootstrap contains `bootstrapId`, `deviceId`, `uid`,
`initialPatchInfo`, `streamingBase`, and historical `lifecycle`. The evidence
contains `bootstrapId`, `uid`, `receiverInitialPatchInfo`,
`calibrationPatchInfo`, and `encryptedFram`. These values are restricted to the
store/driver/decoder boundary, not UI events, telemetry, or diagnostic strings.
Factory evidence remains optional and does not establish current lifecycle or
validated glucose. Missing or invalid evidence suppresses conversion rather
than changing the receiver.

## Ownership and persistence

The app's transport adapter must acquire before calling BLE connect. The lease
spans connection, authentication, subscription, reception, and cleanup. Native
reserve and outcome calls require the exact session, bootstrap, and token.
The coordinator rechecks the receiver's full identity and frozen credentials,
not only its UUID. It checks ownership again after a durable counter write;
ownership loss consumes that counter without returning or rolling it back.

`LibreGen1ReceiverLease` reuses the shared exact-owner
`NfcRfTransactionLease`. It syncs the zero-length private owner file and each
containing directory before returning authority. Existing capture files and
operation journals remain unchanged; an existing lease, including a partial or
empty lease directory, blocks acquisition. The NFC read-only backend already
refuses an existing receiver file and uses this same lease. No receiver is
copied between the debug and signed app containers.

Normal BLE cleanup must finish before release. A thrown connect without a
cleanup handle, timeout, app pause, listener cancellation, or engine destruction
is not proof that BLE closed. The `transportClosed` argument is an assertion by
the trusted app transport adapter, not an Android system observation. Tests and
physical evidence must establish that adapter's close contract before the path
is enabled. Native engine destruction deliberately retains an unresolved lease.

`LibreGen1ReceiverTransport` wraps only the Libre driver's transport. It requires
single-attempt connection support, checks the protected target, acquires before
connecting, and does not offer OS bond creation/removal. Its physical-close
deadline is five seconds; native release has a separate three-second deadline,
both below the driver's fifteen-second outer close bound. A late physical close
cannot release the lease. A lost native release reply keeps the Dart owner
blocked even if native cleanup already completed. No late result or fallback
to the capture channel can make that owner reusable. Login outcome replies
must match the exact null acknowledgement contract.

Release performs fallible ownership checks and directory sync before removing
the exact owner and directory. No fallible operation follows successful
directory deletion. Partial deletion retains a restart blocker. A failed
release or observed ownership loss permanently quarantines that binding in the
current process; a late result cannot revive it. Confirmed transport cleanup
can release a healthy lease even when the receiver store became unreadable,
without changing any receiver bytes. A subsequent restore still fails closed.

## Recovery limits and verification

A process crash with a held lease currently requires a separately reviewed
recovery proof. A new process cannot adopt, erase, or release that owner with
an old token. This is a remaining release blocker, not a reason to clear app
data. Counter exhaustion, unknown enrollment outcome, Keystore failure, and
receiver replacement likewise do not trigger reset or automatic retry.

Do not implement crash recovery by checking public Android `STATE_OFF` and
deleting an old lease. The reviewed [AOSP adapter implementation](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/framework/java/android/bluetooth/BluetoothAdapter.java)
maps BLE-only states to that public value. It therefore does not prove GATT
cleanup. A later recovery design needs an explicit durable receiver-owner type,
exact process incarnation and receiver binding, plus an authoritative transport
cleanup barrier serialized with acquisition. Legacy or partial owners must not
be reinterpreted as recoverable receiver leases. No automatic Bluetooth toggle,
receiver deletion, or login-counter rollback is a recovery fallback.

`./scripts/test-libre-nfc-java.sh` passes all 19 synthetic JVM suites after
this slice. The new coordinator suite covers positive absence, pending/corrupt
records, pure reads without authority, exact/idempotent ownership, credential
substitution, durable counters, unknown outcomes, stale acknowledgements,
ownership loss after persistence, storage errors, uncertain cleanup, native
exclusivity revocation, unresolved restart, and exhaustion. Android API 28 and
37 source compilation passed. These checks do not establish physical RF,
background execution, process-death recovery, decoder accuracy, or release
support. The subsequent full `make check` passed, including Android/web builds,
unsigned iOS and macOS preview builds, eight iOS and two macOS native tests,
and 1,239 unit/widget tests across the workspace. Independent review found no
open P0/P1/P2 issue in these bounded components. Actual transport-close and
process-death recovery evidence remains required before enabling them.

The later opt-in composition slice passes 112 focused Flutter tests and all 21
synthetic JVM suites in `./scripts/test-libre-nfc-java.sh`; analysis reports no
issues for its eight changed Dart source/test files. Tests exercise the actual
mixed registry through exact receiver restore, one synthetic login, and lease
release only after transport close. They also cover unavailable/malformed/late
capabilities, stale bootstrap removal, wrong targets, and saved-receiver UI
without NFC streaming authority. No Android build, install, physical validation,
or release ran for this wiring slice; those checks remain required.

The later saved-receiver history slice passes 30 platform, 40 sync, and 22 pane
tests, plus the 19 focused composition/tools tests. The broader final check
passes 1,871 unit/widget tests and one integration test across the workspace,
all analyzers, formatting, and tooling. All 22 JVM suites pass, including 14
new receiver-history test groups with per-read/per-binding cases. Android Java
compilation passes. Tests verify unchanged receiver/counter state, rotated NFC
seeds, exact stop before handoff, expired/one-use evidence, pending-start
cancellation, blocked-journal pause revocation, and a later unknown RF owner.
Independent review found no remaining P1/P2 in this bounded integration.
Physical validation and release qualification remain separate.

## Reception and setup presentation

Setup completion is separate from current-glucose acceptance. The app checks
the exact selected driver, device, and receiver storage identity; a live session
must report a durably committed `validatedPacket` with `observed` timing and
an in-range sensor minute. Both `ready` and history-only `syncing` snapshots
use this rule for Libre selection promotion. Other drivers keep their existing
ready-state rule. Restored history and a ready-looking snapshot without the
commit evidence cannot establish Libre ownership.

The setup UI also waits for selection persistence and rejects a pending
connection, disconnect, history pause, or uncertain cleanup. It rechecks before
closing the route. A settled save error uses a closed error/recovery view instead
of a locked progress screen. It does not expose native exceptions or reset the
receiver. A current glucose value remains subject to the existing decoder,
provenance, warmup, and freshness checks; finishing setup cannot promote a
historical value to current glucose.
