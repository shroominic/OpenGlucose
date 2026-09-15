# Sensor protocol implementation workflow

Use this playbook to add a sensor driver or fix a live sensor defect without
turning one successful handshake into an unsupported release claim. It records
the method used for Libre 2: inspect references, capture one controlled step,
reproduce the defect offline, repair it, then verify the full app journey.

Follow the [engineering standards](../engineering/standards.md),
[package boundaries](../architecture/README.md), and
[compatibility policy](../compatibility.md). This document does not authorize
sensor commands. Keep protocol data and device artifacts private.

## 1. Define the exact target and evidence boundary

- Record an owner, task, isolated worktree/source revision, acceptance criteria,
  exclusions, and R0–R3 risk class. Assign an independent reviewer.
- Identify model, region, generation, firmware where observable, phone/OS, app
  entry point/build, and test condition. Keep serials and addresses only in the
  approved private case index, never in filenames, fixtures, or PRs.
- Separate **observed**, **reference-derived**, **hypothesis**, and **not tested**.
  A shared name or UUID does not identify a protocol generation. An expired
  sensor on fruit can test communications, not validate body-glucose accuracy.
- Inventory reference repositories locally before adding dependencies. Pin
  the public source commit, exact files/call sites, per-file license, inherited
  code provenance, and notices. Trace the actual transport call, not only a
  command constant or unused function. A Dart rewrite does not change a
  source's license. Follow [ADR 0004](../architecture/adr/0004-private-libre-glucose-decoder.md)
  for the separate Libre decoder; do not label its combined executable MIT-only.
- Keep committed tests synthetic. A published, licensed interoperability vector
  requires explicit provenance review; it is not permission to add a private
  capture. See the [Libre evidence boundary](../../packages/cgm_libre2/doc/evidence-boundary.md).

Record the result with the [variant contract and branch matrix](sensor-variants.md).
Optional `CgmSessionInfo.sensorVariant` carries observed identity information;
it does not grant support, choose a data profile, or authorize a command. Keep
software, firmware, and hardware revisions distinct. Leave unknown regions
unknown rather than deriving them from a name, phone locale, or patch signature
without an evidenced mapping. A later archive can retain the descriptor, but
an active reconnect must obtain its identity evidence again.

## 2. Map all operations before implementing the happy path

For each row, record the exact precondition, transport, required response and
post-state, durable effects, cancellation rule, timeout, and retry policy.
Mark an unsupported operation explicitly; do not implement it by guessing.

| Operation | Evidence and behavior to establish |
| --- | --- |
| Discover / identify | Advertisement freshness, exact model/security branch, supported topology, platform permissions. A saved receiver is not a nearby observation. |
| Read / bootstrap / activate | Which step is read-only, which changes the sensor, fresh same-target evidence, authorization lifetime, and verified post-state. Do not activate an active sensor. |
| Authenticate / subscribe | Exact write mode, acknowledgement ordering, fragment boundaries, counters, and integrity checks. Receiving bytes is not glucose conversion. |
| Stream / synchronize | Current versus historical samples, units, age, gaps, deduplication, timestamps, retention, warmup, expiry, and invalid samples. |
| Disconnect / reconnect | Local transport cleanup versus physical link loss; which credentials survive; fresh login evidence; bounded recovery and uncertain-cleanup blocking. |
| Forget / replace / transfer | Distinguish clearing app selection, archiving readings, changing the receiver, and deleting an OS bond. Define each separately. Never reuse another vendor's unbind command. |
| Calibrate / stop / reset | Factory conversion is not manual calibration. Require a proven capability, explicit intent, durable outcome, and a recovery contract for each sensor-changing operation. |

Use current [session contracts](../../packages/cgm_core/lib/src/cgm_session.dart)
and [capabilities/models](../../packages/cgm_core/lib/src/cgm_models.dart).
Keep vendor parsing and state machines in their driver package. Inject the
[BLE transport](../../packages/cgm_ble/lib/src/ble_transport.dart); keep native
permissions, foreground ownership, and protected storage in the app. Do not
expand core contracts with vendor-only fields just to complete one screen.

## 3. Start recording before contact or app startup

For Android, read the full [capture runbook](../runbooks/libre-protocol-capture.md)
before running commands. Its strict app/user/profile binding and neutral labels
are authoritative. The harness does not authorize the app's radio operations.

Choose observation-only or full product UI **before** starting. Full UI can
restore and reconnect existing sensors. Use it only when that activity is in
scope. Keep the selected profile and live-driver flags fixed for the session.
The example below is the observation-only Libre baseline, not a live decoder:

```sh
# Repository root. Substitute approved private locations/device selection locally.
export OPENGLUCOSE_CAPTURE_ROOT=/absolute/private/path/sensor-captures
export ANDROID_SERIAL=authorized-adb-serial
export OPENGLUCOSE_CAPTURE_PROFILE=libre
export OPENGLUCOSE_CAPTURE_LIVE_AIDEX=false

./scripts/libre-protocol-capture.sh doctor
# The installed debug app must be stopped. Keep the sensor away from the phone.
LIBRE_CAPTURE_SESSION=$(./scripts/libre-protocol-capture.sh start \
  --package com.openglucose.app.debug)
```

After `start` completes, launch the chosen build in a second terminal with the
same authorized device selection. For the observation baseline:

```sh
cd openhealth
flutter run --debug -d "$ANDROID_SERIAL" \
  --target lib/protocol_capture_main.dart \
  --dart-define=OG_PROTOCOL_TRACE=true \
  --dart-define=OG_PROTOCOL_CAPTURE_PROFILE=libre \
  --dart-define=OG_PROTOCOL_CAPTURE_LIVE_AIDEX=false
```

Back in the harness terminal, from the repository root:

```sh
./scripts/libre-protocol-capture.sh verify-app-ready \
  --session "$LIBRE_CAPTURE_SESSION"
./scripts/libre-protocol-capture.sh snapshot \
  --session "$LIBRE_CAPTURE_SESSION" --label 01-app-idle
```

Readiness requires two advancing, exact-process status samples, not a logcat
PID or a vibration. See the [status schema](../testing/libre-protocol-capture-status-schema.md).
Do not run host `start` again while the app is running. Reuse the host session
for app restarts and verify readiness again before a new sensor action.

For the later Libre live-UI bench phase, the existing guarded entry point is
[`libre_glucose_debug_main.dart`](../../openhealth/lib/libre_glucose_debug_main.dart),
not the observation app. Select its reviewed live flags and matching host mode
as a deliberate session configuration; do not silently change the baseline.
This entry point is private decoder validation, not a release configuration.

## 4. Execute one authorized step and inspect its result

1. Record the intended action and expected closed outcome. First contact and
   target-unverified RF remain R3 while effects are unknown. A command called
   “read” in a reference is not enough to downgrade that risk.
2. Capture a neutral before-snapshot. Confirm one foreground/RF owner, fresh
   same-target evidence, current process/build, and bounded authorization.
3. For a sensor-changing command, persist intent before transmission. Reserve
   counters durably before use. Permit one reviewed sequence; do not add an
   alternate frame or automatic retry because the first attempt timed out.
4. Capture the response, post-state, and confirmed transport/lease cleanup.
   A response of the right length is not proof of activation or ownership.
   An uncertain outcome retains its journal and blocks replay. Do not delete
   credentials, clear app data, roll back counters, or unpair to bypass it.
5. Take an after-snapshot and inspect it before asking for another tap. Report
   the last proved state and the next necessary physical action. A vibration
   alone is not a successful read; a stale setup proof needs a new explicit
   read, not replay of a possibly completed write.

Use the command-specific grants and stop rules in the runbook; do not copy
raw command bytes from a capture into a shell. During an active Libre BLE
session the scanner is intentionally suspended. An advancing healthy recorder
can coexist with NFC RF eligibility being false; do not resume scanning merely
to make an NFC-readiness check green.

## 5. Turn each finding into an offline regression

Keep raw artifacts unchanged outside Git. Verify each snapshot's complete
manifest, selected process/trace binding, and chronology before analysis. Work
from the current trace, not a file selected by its highest sequence number.
Screenshots must actually show our app; an unrelated foreground app is not UI
evidence. HCI snoop does not record NFC, and capture gaps must remain explicit.

For each defect:

1. State the observed failure separately from its proposed cause. Compare
   operation-start, acknowledgement, notification, and cleanup order.
2. Construct the smallest synthetic failing test at the owning layer. Inject
   clocks, transport, storage, and completion barriers instead of fixed sleeps.
3. Apply a contained fix. Add negative cases: wrong model/target, invalid CRC,
   truncated/reordered fragments, duplicate samples, stale callbacks, late
   acknowledgements, double taps, background/back-navigation cancellation,
   storage errors, and cleanup failure.
4. Obtain independent source review and run the focused tests before deployment.
5. Update through `flutter run`, preserving app data and protected state. Use
   lowercase `r` only for applicable Dart hot reload; `R` is hot restart and is
   not equivalent. Native changes require a rebuilt process. After any restart,
   re-establish recording evidence; do not assume the earlier proof survived.
6. Repeat only the affected **safe** step. Verify the fix in trace and UI, then
   check for unintended extra connections, writes, or sensor-state changes.

Current examples: [single-attempt transport](../../packages/cgm_ble/lib/src/ble_transport.dart),
[Libre driver regression tests](../../packages/cgm_libre2/test/gen1_live_driver_test.dart),
and [native file-policy tests](../../openhealth/android/app/src/test/java/com/aidex/aidex_flutter/LibreGen1StreamingFilePolicyTest.java).

## 6. Verify data and the whole product journey

- Separate transport integrity, decryption, raw fields, calibrated conversion,
  and validated display quality. Do not convert ADC values by an assumed scale.
  Bind factory evidence to the exact receiver/sensor and preserve it through
  first setup, restart, and independent capture rotation. Keep initial security
  metadata distinct from current calibration metadata when the protocol does.
  A saved-receiver restart does not test first enrollment. Validate that branch
  with a separately approved fresh setup, not by deleting an existing journal.
- Publish immutable normalized snapshots. Keep received history separate from
  sensor backfill. Retain original timestamps and quality flags; do not infer
  sample time or sensor start from the latest receipt without proven semantics.
  Deduplicate across recovery and persistence. Do not fill missing intervals.
- Verify multiple readings arrive and remain stored. Restart with retained app
  data: historical points must survive, while Searching must not show an old
  point as a current live reading. Compare earlier records unchanged, then
  confirm newly received points append correctly.
- Test normal Disconnect, its archive/selection behavior, and explicit saved
  receiver reconnect separately from range loss and automatic recovery. Prove
  no activation, enable-streaming replay, bond deletion, or calibration rewrite
  occurred where none was intended. Test unknown cleanup and partial storage
  failure without claiming that closed Dart streams prove physical teardown.
- Test warmup-to-active, expiry, stale data, invalid samples, phone/app restart,
  Bluetooth off/on, background operation, counter exhaustion, and unavailable
  protected storage. Record untested branches as blockers, not success.
- Keep provisional/raw points visibly qualified. Verify their persistence,
  archive, explicit export, wellness/AI, HealthKit, and lock-screen policy at
  each boundary. Local history retention does not grant export permission.
- Keep the multi-sensor UI Bluetooth-first. Route uncommon setup through model
  help; do not start NFC for a user selecting AiDEX/LinX. Expose only supported
  actions and preserve existing vendors' connection/history/transfer behavior.

## 7. Close the evidence and release gates

Run focused package/native checks during iteration. Before integration, use
the repository contract: `make check`, plus applicable sensor-native runners
such as `./scripts/test-libre-nfc-java.sh`. Record each actual command, result,
source revision, and limitation. The deferred `test-e2e` lane is not a passed
physical test. A web build or Java compile is not a mobile device validation.

Before distribution require clean reviewed source, affected native builds,
cross-vendor checks, exact-model/in-date validation, license approval, normal
release-path integration, source-bound signed artifacts, and a recovery plan.
Keep diagnostic recording optional in production without removing the durable
journals needed for sensor-changing operations. Follow the current
[Libre release gates](../testing/libre2-release-readiness.md) and
[production integration plan](../testing/libre2-production-integration.md);
do not enable debug flags to create a production support claim.

End collection with the runbook's `stop --session` command when authorized to
stop the debug app. It takes a final snapshot, disarms grants, stops that app
and the bound logcat process, and hashes the closed session. A bugreport needs
separate privacy approval. Apply the agreed private-artifact retention policy.

## Reusable evidence report

Use this redacted template in the task/PR. Keep raw artifacts and the mapping to
their private locations in the owner-controlled case index, not in this report.

```text
Scope / owner / risk / source revision:
Exact model, generation, region, firmware evidence / phone OS / build entry point:
Reference commits, files, licenses, and unverified assumptions:
Variant descriptor source / observed fields / unknown fields / exact branch gate:
Approved operation / pre-state / expected post-state / excluded operations:
Capture binding and full manifest verification: pass | fail | not available
Observed result: closed states and counts only
  UI state and reading count:
  Successful connect / discovery / acknowledged login / subscribe counts:
  Complete packets / rejected samples / duplicate or gap counts:
  Local cleanup versus physical disconnect / remaining uncertainty:
  Unintended sensor commands or credential changes: absent | present | unverified
Persistence: earlier records unchanged / restart restoration / new points appended
Failure → synthetic regression → fix → independent review → physical recheck:
Commands actually run and outcomes / tests or platform checks not run:
Evidence proves:
Evidence does not prove:
Release blockers / next bounded action / approval needed:
Private evidence owner and retention decision:
```
