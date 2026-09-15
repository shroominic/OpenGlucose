# Libre 2 release readiness

## Home history-gap prompt (2026-09-12)

The home dashboard now offers a compact **History may be missing** card for a
selected Libre 2 only when the newest retained timestamp is at least ten
minutes old. The card is hidden during setup transitions, while a history read
is in progress, when timestamps are missing, and for every other sensor. It
reuses the existing receiver-bound `LibreNfcHistoryPane`; rendering it does
not start NFC, pause Bluetooth, or grant any receiver authority. The action
continues to require the existing exact-target bootstrap, cleanup barriers, and
fresh-read import policy. The presentation predicate has deterministic tests
for stale, fresh, setup, and in-progress states, plus a dashboard widget proof
that the NFC action stays explicit. A release-workflow contract test also
proves that signed Android releases do not opt into the private GPL decoder.
`make lint`,
`make format-check`, `make test-unit`, `make build-android`, and the full
`make check` contract passed on this worktree after the change. This is UI and
software regression evidence only; it does not add physical NFC qualification,
calibrated-output evidence, or a production support claim.

## NFC history UX follow-up (2026-09-11)

Risk R2; accountable owner `@shroominic`. Scope is the private Android history
flow, not sensor activation, pairing, normal-release enablement, or licensing.

A current-process trace and private restricted-state backup now confirm NFC
history imports on the Pixel. The retained envelope increased from 129 to 177
records: 35 additional NFC-origin records and 13 additional BLE-origin records.
The first NFC acquisition added 34 records (26 history, eight trend), spanning
429 sensor-relative minutes; a later acquisition added one trend record. All
129 previous readings and the three original archive arrays are unchanged, and
frontiers did not regress. The user's reported UI count of 43 is not reproduced
by these retained acquisition batches; do not relabel it as a verified count.
This is one device/receiver observation, not full history-path qualification.

The old app flow deliberately paused BLE for NFC and required a separate
Resume Bluetooth action. After the read, a later link loss and an Android GATT
133 connection failure also occurred; the history UX change does not establish
a fix for that separate transport error.

The panel now requests one exact-saved-target reconnect after a successful
foreground import and complete disposal of the NFC owner. The controller
requires the still-pending history pause, matching selected/stored identity,
confirmed cleanup, and no competing connection; activation stays disabled.
Cancelled/failed reads, backgrounding, route/tools changes, and uncertain cleanup
cannot auto-resume. The panel distinguishes historical import count from BLE
reconnect progress and states the eight-hour buffer limit. NFC still temporarily
pauses BLE; simultaneous NFC/BLE has not been qualified.

The regression failed before the change. All 90 focused history/composition
tests, all 1,105 app unit/widget tests, and app static analysis pass. This slice
does not claim a new full-workspace `make check`, CI result, or independent
review. Device verification of the new automatic handoff is pending. No sensor
reset, unbind, activation, credential migration, PR merge, or release is part of
this slice. Previous checkpoints below remain historical evidence.

Flutter built, installed, and launched the updated private debug entry on the
Pixel with a live Flutter connection. A fresh-process capture was healthy and
the saved receiver reconnected without NFC. A second backup showed 183 retained
readings, with all 177 pre-update readings, original archive bytes, and monotonic
frontiers preserved. This verifies restart/restore plus new BLE reception on
this build, not yet the post-NFC automatic handoff. The history reader was not
started by opening Settings.

Status: private Android bench validation, not ready for a stable sensor-support
claim. Accountable owner: `@shroominic`. Updated: 2026-09-11.

The current repair is R2 (Bluetooth connection and setup UX). It does not change
the already approved one-shot activation or streaming NFC command sequence.
Any production sensor command or external distribution retains its R3 gate.

Current hardware checkpoint: the returned Pixel runs the private capture debug
entry. Its latest checked history increased from 32 to 129 retained readings. The original
readings and three archive arrays are unchanged across hot reloads. Independent
provenance validation of the latest 129-reading backup finds 46 added BLE live,
45 BLE trend, and six BLE history
records, with valid first-receipt and source-relative timestamps. Exact-process
trace validation confirms five successful BLE connections. One
explicit NFC history window stopped without a detected tag, so no NFC import is
proven. Bluetooth later switched off, and the debug shared scanner retained an
exhausted Bluetooth-off failure even after the radio returned on. After the
bounded recovery repair, one explicit retry reconnected and resumed reception.
A later bounded three-minute background check received fresh packets in the
same process without a reconnect. This is not recorder-free hardware,
screen-off/reboot, or long-duration reception qualification.

Earlier applied checkpoint: the frozen archive, clear, and restart review slice
passed the full local checks: 1,372 unit/widget tests, one integration test,
native checks, and Android, web, iOS, and macOS builds. Flutter completed a hot
reload into the attached debug app. A read-only backup comparison verified all
three original archives and their 32 readings unchanged. After unlock, an
explicit saved-receiver connection created a bound history envelope through
the real app path. Independent backup verification confirmed all 32 readings
were retained unchanged. Foreground capture remained healthy, but the bounded
connection attempt found no advertised target. Fresh connection and streaming
remain unverified; see the separate hardware checkpoint below.

Newer source-only work implements the fresh NFC history parser, conversion,
schema-two atomic import, connection pause, coordinator, and inline settings
action. Main wiring and private-only factory guards are in place. The focused
coordinator and panel suites pass 32 and 22 tests respectively. The newer source
passes 1,618 unit/widget tests, one integration test, the Android JVM suites,
all workspace analyzers, formatting/tooling checks, the Android release-signing
failure guard, and Android, web, unsigned iOS, and macOS preview builds. The
private NFC-enabled Android debug entry also builds. iOS/macOS native UI tests
were not rerun for this slice; no desktop app was opened. These changes have
not been installed or physically exercised at that checkpoint. The full-check count above
describes the last applied checkpoint, not this newer source.

The subsequent provenance-export slice implements immutable acquisition-bearing
CSV, TXT, and XLSX output. The final broad check passes 1,706 unit/widget tests,
one integration test, Android JVM checks, all workspace analyzers, formatting,
and Android, web, unsigned iOS, and macOS preview builds. Tooling checks and the
Android release-signing failure guard also pass. iOS/macOS native UI tests were
not rerun. The private NFC-enabled Android debug entry also builds. The slice
was uninstalled at that checkpoint because the Pixel was not reachable over USB.

The newer BLE sparse-history slice passes 1,828 unit/widget tests, one
integration test, Android JVM suites, all analyzers, format/tooling checks,
the Android release-signing failure guard, and Android, web, unsigned iOS,
and macOS preview builds. iOS/macOS native UI tests were not rerun, and no
desktop app was opened. The separate private NFC-enabled Android debug entry
also builds. Installation and physical checks occurred later, as recorded below.

The subsequent saved-receiver NFC history integration passes 1,871 unit/widget
tests and one integration test. All workspace analyzers, formatting, tooling,
and the 22 Android JVM suites pass. Android Java compilation passes. Independent
Dart/native review found no remaining P1/P2 in this bounded route. The exact
receiver read uses the existing 16 commands, preserves receiver/counter bytes,
and imports only after read cleanup; cancellation and lifecycle loss revoke
the one-use evidence. Normal main remains decoder-free. Current-slice platform
builds, installation, and physical history qualification are separate checks;
earlier build results do not establish them.

### Returned-device history checkpoint (2026-09-11)

The Pixel returned over USB. Before update, the exact current app trace contained
one physical scan start and continuous recorder heartbeats but no advertisements
or notifications. Retry can reuse the shared physical scan, so no additional
scan-start event alone is not proof of an app hang. Host logging had a USB gap;
no full host/HCI continuity is claimed across it.

The guarded Flutter runner then built, updated, and attached the existing
private **capture** glucose entry. App data was not cleared. Read-only backup
comparisons verified all three original archive arrays and 32 readings unchanged
before and after installation. An explicit saved-receiver connection subsequently
increased the active history envelope to 41 readings and lazily upgraded it to
schema three with an observed frontier. Another backup comparison verified all
original readings retained. A subsequent backup contains 53 readings. Its 21
new entries are four `bleLive`, 15 `bleTrend`, and two `bleHistory` readings;
there are no NFC imports. First-receipt timestamps, packet-slot offsets,
sensor-relative timing, and provisional/vendor provenance validate. Legacy
receipt information remains unknown, not reconstructed. The latest committed
observed minute in that backup has an accepted live reading; the backup cannot
establish rejection reasons for later packets.

An independently bound current-process trace confirms two successful BLE
connections and 15 notification fragments. The explicit settings history action
reached NFC listening, then stopped without a tag, read, or transceive event.
Bluetooth was explicitly resumed. Thus NFC history import remains physically
unverified. These are bounded live/sparse-history results, not sustained
background reception or recorder-free backend qualification. Independent
private all-buffer host logging is running; the old harness process fingerprint
is not reused as continuity proof.

### Reception presentation and radio recovery checkpoint (2026-09-11)

Setup completion now requires exact-receiver, durably committed observed data
and completed selection persistence. It does not require a current glucose
value, and a provisional or historical value does not become current. Settled
persistence errors offer retry; uncertain cleanup retains the restart-only
barrier. Sensor details distinguish a true history sync timestamp from the
latest stored sample. Empty, untimed, and future-dated records do not acquire
the current wall-clock time. These changes passed full app analysis and 1,081
app tests before the scanner recovery change. They were hot-reloaded into the
existing process without reinstalling or clearing app data. Public runtime
inspection confirms the new verified-reception helper is loaded.

A bound current-process trace contains 78 notification fragments from two
successful connections, but its last notification was over 29 minutes old at
export. Its recorder was healthy; it does not prove current streaming. Native
Android and the Bluetooth plugin both reported on after explicit radio enable,
while app retry immediately returned the old cached Bluetooth-off error.

The debug shared scanner now allows a new valid logical scan to rearm only a
classified Bluetooth-off exhaustion with confirmed scan cleanup, no connection
owner, no pending cancellation/retry, and no active physical scan. Automatic
retry remains bounded; old listeners remain closed; a new native-start
acknowledgement is still required. Direct connect and bare `start()` do not
clear exhaustion. A newer untyped error, unexpected stream completion, or
retry-delay error cannot inherit an older Bluetooth-off classification. Failed
or timed-out cleanup remains quarantined. The 35 scanner tests pass. Full app
analysis and 1,090 app tests, plus the explicit integration test, passed before
the chart change below. Runtime inspection verified the new scanner code and
the existing exhausted instance with no held scan or connection owner. One
ordinary dashboard retry then started a fresh native scan, matched a sensor
advertisement, completed connection/discovery/login/subscription, and received
three notification fragments. A private backup verified 76 to 86 retained
readings, then 99 without another retry. All prior envelope readings and the
three original archive arrays remain unchanged. No bond, enrollment, activation,
receiver reset, or APK install was needed. The latest-bound recorder is healthy,
but it contains a prior long heartbeat gap; continuity is not claimed across it.

The phone chart exposed a separate presentation fault: it drew continuous lines
across long missing intervals and crowded time labels. The chart now separates
intervals over 15 minutes or clock discontinuities before aggregation, and both
line and area fill respect each segment. This is a display limit, not inferred
sensor cadence. Label collision checks preserve the latest time. The final
app analysis is clean and all 1,094 app tests pass, including 11 chart tests.
The chart code was hot-reloaded into the same connected debug process. A phone
screenshot confirms the missing interval is blank and time labels do not
overlap. Current sensor settings show `Latest stored reading`, and the displayed
history reached 104 records while the same connection remained open. This
screen count is separate from the independently checked 99-record backup. New
platform builds, independent final review, sustained background qualification,
and physical NFC import remain outstanding.

### Repeated link loss and bounded recovery renewal (2026-09-11)

A later exact-process trace shows two physical disconnects during that run.
The original one-shot recovery succeeded, and its replacement received seven
more complete packets. The second disconnect stopped the session because its
single lifetime recovery was already consumed. Host/plugin evidence reports
status 8 (`LINK_SUPERVISION_TIMEOUT`); this is not evidence of a bond failure.
The cached Bluetooth-off repair remains valid, but it does not fix radio loss.
The phone retained 104 readings when this second failure appeared.

The durable driver now earns one further bounded recovery only after three
fresh committed observations span at least two monotonic minutes on the same
replacement. Consecutive receipt and sensor-minute steps must stay within two
minutes, and the most recent receipt must still be within two minutes when the
link fails. Setup success, replay, stale observations, imported history, failed
or pending commits, and wall-clock changes cannot create this evidence.
Confirmed cleanup, exact-bootstrap reread, a new advertisement, and a fresh
durable counter remain mandatory. Each unsuccessful replacement stops; there
is no blind retry loop. No-store callers retain the old lifetime limit.

The source passes all 419 Libre package tests (210 driver tests) and 1,094 app
tests, with both analyzers clean. Tests cover repeated healthy recoveries,
minute/clock gaps and rollback, replay, stale evidence, insufficient evidence,
pending commits, cleanup failure, target replacement, reservation failure,
and cancellation. Hot reload into the same private process is verified. A new
explicit session received data and retained 118 readings, with all prior data
unchanged. A three-minute background check then confirmed the same process and
binding at every export, healthy capture, and new notification fragments at
the 60-, 120-, and 180-second background checkpoints. Android independently
reported the app not resumed. No connection or disconnect occurred in that
window. The initial command to return the task to the foreground was rejected
by Android; the app remained in the background. The later foreground command
used the supported numeric launch flags and preserved the same process,
installed build, and capture binding. A screenshot then verified the app was
actually on screen. A successful shell exit alone is not foreground evidence.
The subsequent backup has 128 readings and preserves the 118-reading envelope
and every original archive. This short check does not establish screen-off,
reboot, long-duration reception, or renewal after multiple real dropouts.

The canonical workspace lanes now pass: 1,926 unit/widget tests, one integration
test, Android JVM checks, all analyzers, and formatting. The app's 1,094 full
test count above includes its one integration test; do not add that test twice.
Independent final review is not available because all three review agents are
quota-blocked. No review waiver, production enablement, commit, or distribution
was performed for this repair.

### Post-background connection checkpoint (2026-09-11)

After the three-minute window, the physical link dropped again. The driver
entered its bounded recovery scan, but no fresh target advertisement arrived;
the attempt ended with the sensor-not-found error. The native Bluetooth dump
confirms the radio is on and a scanner is registered with the same two service
filters used by the earlier successful connections. That scan returned zero
matching advertisements. This is not evidence that no nearby Bluetooth device
exists, and does not by itself prove a scanner defect or a sensor fault.

Bringing the existing task forward restored runtime inspection. An ordinary
dashboard retry started a new owned session and a foreground connection service,
without a reset, bond change, enrollment, or reinstall. Fresh reception and a
second successful automatic recovery are not yet verified. The latest read-only
backup contains 129 readings. Independent provenance checks confirm 46 added
BLE live, 45 BLE trend, and six BLE history records since the 32-record baseline;
all original fields, timestamps, archive bytes, and unknown legacy receipt
provenance remain unchanged. No NFC import is present. The current-source
canonical Android debug build also passes; it was not installed or distributed.

The same current source also passes the canonical web, unsigned iOS, and macOS
preview builds, Android release-signing failure guard, and pinned tooling/
workflow contracts. The private capture glucose entry and the separate
recorder-free saved-receiver glucose entry both build for Android debug. The
latter's merged manifest confirms the explicit read-only selector; neither
artifact was installed. App and native dependency lockfiles are unchanged.
Flutter was reattached to the existing capture app after the builds. Native
iOS/macOS UI tests were not rerun, no desktop app was opened, and no CI, final
independent review, signed release, or external distribution is claimed.

### Waiting for a returning sensor (2026-09-11)

The post-background failure exposed a separate product gap: even a previously
working durable session ended its recovery when the sensor did not advertise
within the 150-second initial setup window. A synthetic regression reproduced
that terminal error before the fix.

An earned durable recovery now holds one cancellable FDE3-filtered scan while
the sensor is absent. It does not create repeated scans, reserve counters, or
retry login writes. The waiting snapshot clears current glucose and live timing,
retains history, and displays Waiting with explicit return-to-range guidance.
Its owned Android connection service remains active without publishing glucose.
After a fresh exact advertisement and confirmed scan cleanup, a new protected
bootstrap read must confirm the same receiver within 15 seconds before one
connection is allowed. Cancellation, native scan failure/closure, unknown
cleanup, and changed/missing/unreadable credentials terminate the wait. Initial
setup and no-store callers retain their original deadline.

The focused driver suite passes 222 tests. The presentation and Android
connection-lifecycle suites pass 75 tests. New cases cover return after the setup
deadline, stale/future/wrong-target advertisements, no counter use while absent,
delayed scan cleanup, target replacement during cleanup, credential-read timeout
and late completion, cancellation, native failure, and the original initial
deadline. These are software results; no physical return-to-range success or
NFC backfill is established by them. Independent review remains unavailable,
and the production, conformance, and distribution gates are unchanged.

Final canonical checks for this repair pass 1,940 unit/widget tests, one
integration test, Android JVM checks, all workspace analyzers, formatting,
and Android/web/unsigned-iOS/macOS-preview builds. The Android release-signing
guard fails closed as required. Native iOS/macOS UI tests were not run, and the
build commands did not open a desktop app or install anything on the Pixel.
Both private Android glucose entries also build. The recovery and presentation
changes were then hot-reloaded into the existing capture app; runtime source
inspection confirms the new return-wait helper. This did not create a new
sensor session or establish physical recovery. The latest trace still has no
new target notifications. No initial setup, enrollment, reset, or production
enablement was performed.

Earlier builds restored the receiver without NFC and accumulated points, but
later tests exposed a background process freeze, a separate foreground link
timeout, and unintended reconnect after Disconnect. The service and teardown
repairs passed checks. The prior phone checkpoint confirmed foreground-service
startup and a clean 114-second idle interval after local Disconnect; its live
attempt was remotely terminated during discovery, and retry found no fresh
advertisement. These are not successful streaming results for the current
build. See the dated checkpoints below. Sustained reception, hardware backfill,
Libre transfer/replacement, and normal release integration remain open. No new
regional, firmware, wearable-accuracy, or production support claim is made.

## Current sensor-flow capability audit

This table describes the private Android Gen1 implementation. It does not
extend the normal release registry or establish compatibility for other Libre
generations, regional variants, or sensor firmware.

| Operation | Implemented behavior and remaining boundary |
| --- | --- |
| Identify and read NFC | The explicit reader checks the exact target, Gen1 model, current patch information, and all three FRAM CRCs before returning a closed lifecycle result. `Libre2Gen1ReadTransaction` is now wired to a default-off recorder-free Android reader, with native capabilities and foreground/cleanup guards. Physical validation of that backend remains open. |
| Activate | One debug/host-authorized transaction verifies the pre-state and post-state and preserves a durable outcome journal. One bench activation reached `warmingUp`. This is not an automatic step for an active sensor, and an unknown outcome cannot be replayed. |
| Enable streaming | One journaled NFC operation persists its chosen base before transmission and confirms the response-derived receiver only after close, audit, and lease release. It is not repeated for saved-receiver reconnects. |
| Disconnect locally | The Libre session cancels its local subscriptions and disconnects BLE. It does not remove an Android bond, change the sensor receiver, clear calibration, or reset a sensor. Cleanup uncertainty returns a typed failure, retains the driver lease and saved selection/history, and blocks new connections in that process. The app waits for pending selection persistence before clearing background targets. |
| Reconnect to the same receiver | An explicit connection rereads protected bootstrap state, waits for a fresh exact-target advertisement, reserves a new durable login count, writes F001 once, then subscribes to F002 after acknowledgement. One bounded recovery and one quit/reinstall/run restore have bench evidence. They do not prove continuous background operation. |
| Unbind or move to another phone | Not implemented for Libre. The session has no `CgmBondTransferSession` or unsafe-admin implementation. The existing AiDEX Bond Management Service procedure must not be reused for Libre. The pinned reference's Bluetooth-disable comment is not a reviewed transfer protocol or recovery contract. |
| Reset, stop, or extend a sensor | Not implemented. A generic reference UI task name or command comment is not evidence that a Gen1 operation is safe, reversible, or supported. Do not replay activation or delete receiver state to simulate reset. |
| Replace an expired sensor with a new sensor | Not implemented end to end. `LibreGen1StreamingJournal.prepare` refuses any existing record, and the store has one receiver file. A reviewed archive/replacement state must retain old receiver identity and consumed counters; deletion or counter rollback is not a replacement design. |
| Factory conversion | The separate GPL decoder uses same-sensor CRC-verified FRAM, the current FRAM patch seed, factory coefficients, and temperature correction. The frozen Bluetooth patch is kept separate. Accepted output is provisional bench data, not validated body glucose. |
| Manual calibration | Not implemented for Libre: calibration capability is false, fetching returns no entries, and submission rejects the operation. No audited Libre command writes a finger-stick correction to the sensor. A possible future local correction needs its own validated model and provenance; it must not overwrite factory evidence. |
| History | The driver retains accepted current samples with original UTC receipt times and quality flags. The private explicit app action coordinates a fresh NFC FRAM read, conversion, and receiver-bound history import, preserving acquisition origin and first receipts without creating live-reading evidence. The inline settings panel is installed in the private capture build; a successful physical NFC import remains unverified. Provenance-aware archive export and actual compute/share UI tests pass with the earlier broad software checks below. BLE backfill retains accepted older packet samples in schema-three storage, with the returned-device evidence above. Unavailable intervals remain gaps. |
| Process restart | The protected receiver and calibration survived one full Flutter quit/reinstall/run with retained app data. The new process connected and displayed a bench estimate without NFC. Reboot, Keystore loss, process death during an unknown write, and signed-app migration remain unverified. |
| Android release / iOS | Normal Android builds do not register Libre or the NFC capture bridge. The existing read-only opt-in composes a recorder-free saved receiver in Android debug only, with strict capability and ownership checks. Normal main has no decoder; the explicit private glucose entry can supply protected calibration and the exact-receiver NFC history route. Neither path enrolls a sensor. iOS has no Libre/CoreNFC bridge, and the current receiver ID contract expects an Android MAC address. Neither a release flag nor an iOS NFC entitlement alone closes these gaps. |

Code evidence: [driver capabilities and session](../../packages/cgm_libre2/lib/src/gen1_live_driver.dart),
[receiver journal](../../openhealth/android/app/src/main/java/com/aidex/aidex_flutter/LibreGen1StreamingJournal.java),
[native bridge](../../openhealth/android/app/src/main/java/com/aidex/aidex_flutter/DebugProtocolCaptureBridge.java),
[debug-only composition](../../openhealth/lib/src/driver_factory_io.dart), and
[calibration decoder](../../packages/cgm_libre2_glucose/lib/src/decoder.dart).

Pinned primary evidence distinguishes
[Gen1 enable-streaming and retained initial patch](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift#L176-L230)
from [restore and fresh login count](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/BluetoothDelegate.swift#L504-L539).
The separate Libre 3 receiver-switch declaration and Gen1 Bluetooth-disable
comment in [NFC.swift](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/NFC.swift#L60-L104)
do not establish a complete Gen1 unbind/reset procedure. Android
[reader mode is foreground-scoped](https://developer.android.com/reference/android/nfc/NfcAdapter#enableReaderMode(android.app.Activity,%20android.nfc.NfcAdapter.ReaderCallback,%20int,%20android.os.Bundle));
the production coordinator must preserve explicit foreground ownership.

### First-time calibration persistence repair

The audit found a first-time setup gap: an explicit NFC read cannot save
receiver-bound calibration before a receiver exists. The streaming transaction
previously discarded its verified FRAM before confirming the receiver, and did
not save a cache after confirmation. The successful restart above used an
already-confirmed receiver and therefore did not test this first-time branch.

[LibreGen1StreamingCalibration](../../openhealth/android/app/src/main/java/com/aidex/aidex_flutter/LibreGen1StreamingCalibration.java)
now retains the existing transaction's exact CRC-verified evidence in a
single-use native object. The bridge saves it only after durable receiver
confirmation, proven transport close/audit/lease release, and the same healthy
native epoch, generation, process, and idle RF ownership checks. The save uses
the existing encrypted cache and verified readback. It does not add a sensor
command, change a login count, rewrite the receiver, or import a capture file.
All terminal paths clear the retained buffers. A failed cache save remains a
closed diagnostic and cannot fabricate a glucose reading or trigger NFC retry.

The [synthetic regression](../../openhealth/android/app/src/test/java/com/aidex/aidex_flutter/LibreGen1StreamingCalibrationTest.java)
covers first setup, volatile-source loss, both patch roles, each CRC region,
wrong/replaced receiver, unconfirmed or unreleased completion, failed writes,
single-use behavior, and buffer clearing. All 14 native JVM suites, seven
focused Flutter safety tests, and offline Android Java compilation passed.
Independent native review found no blocking issue. This repair is **not yet
physically verified**: do not replay streaming enablement on the current bench
receiver to test it. Use the next separately approved first-time sensor setup.

### Remaining publication work, in order

1. Complete the remaining device verification of the cache, UI, and
   provisional-data policy below. Multi-point receipt, history restoration,
   normal disconnect, and archive preservation now have bench evidence.
   Caller-visible uncertain-disconnect behavior and first-time calibration
   retention still need physical verification; synthetic tests are not enough.
2. Implement the [recorder-free Android integration slices](libre2-production-integration.md).
   Preserve state-changing journals and exact RF ownership; do not replace
   trace reservations with an unconditional success stub. Physically verify
   the receiver-store hardening below before promoting it to production.
3. Design safe new-sensor replacement and recovery for unknown outcomes,
   counter exhaustion, update/reboot, and Keystore loss. Receiver transfer or
   reset needs separate protocol evidence and R3 approval, not a local clear.
4. Verify current sensor age/lifecycle, warmup transition, expiry, stale and
   invalid readings, long-duration background operation, and mixed AiDEX/LinX
   behavior on the intended release build. Add iOS NFC and native receiver
   storage as a separate platform implementation before any iOS Libre claim.
5. Complete exact-model expected-glucose conformance with an in-date wearable
   sensor and a trusted reference. The fruit bench cannot supply that evidence.
6. Resolve the [GPL combined-distribution gate](../architecture/adr/0004-private-libre-glucose-decoder.md),
   exact-source notices and source offer, platform/store compatibility, clean
   CI, source-bound signed artifacts, and release/rollback approval. No APK or
   TestFlight production support claim follows from the private bench result.

## Confirmed bench evidence

- One activation completed with a verified post-state of `warmingUp`.
- The separate NFC streaming exchange returned the expected successful shape;
  the response-derived Bluetooth target matched subsequent advertisements.
- The first direct connection timed out after 15.04 seconds, before discovery,
  login, or notification setup. The first matching advertisement in the trace
  was observed 25.08 seconds after the failure. Scanning was suspended during
  connection, so this does not establish when the sensor began advertising or
  prove an Android address-type cause.
- Protected captures, screens, and receiver state remain outside Git. No
  activation or streaming enable replay is required to test a new BLE attempt.
- A fresh full-process recording later contained 72 exact-target advertisements
  over 243.32 seconds. The largest gap was 118.92 seconds; the median gap was
  0.07 seconds. This is evidence of brief, widely spaced bursts on this bench
  sensor, not a universal Libre advertising interval. Six-second UI scans can
  miss these bursts. Saved receiver selection must not depend on that window,
  and the connection wait must cover the measured gap.
- A Dart hot restart completed but recorder readiness was lost. A full Flutter
  quit/run restored healthy advancing capture without deleting app or receiver
  data. The exact incident cause remains unproved. Review found unbound stale
  stop/status and revocation-epoch risks; do not claim hot-restart recovery is
  validated or bypass recorder readiness to retry a sensor operation.
- The final repaired BLE attempt succeeded after read-only saved-receiver
  restoration and fresh-advertisement wait. Exactly one physical connect took
  213 ms; discovery took 883 ms, the with-response login write 134 ms, and
  notification enable 116 ms. Three notification fragments arrived and the
  app reached `validatedPacket` (decryption plus packet CRC validation).
  The first-composite state and trace were saved privately. No NFC command was
  repeated. This proves the observed bench handshake, not calibrated glucose.
  A later snapshot contained six notification fragments, still one physical
  connection and no recorded BLE operation failure.
- That same connection later delivered 18 fragments (six CRC-valid composites,
  about one per minute) before a physical disconnect at 363.5 seconds. Android
  reported reason 8, a link-supervision timeout, before local cleanup. The
  trace also showed scanning resumed during the connection. Scanner contention
  is a hypothesis, not a proved cause. Sustained streaming is not yet verified.
- Host `start` is now rejected before any app mutation or RF lease when the
  debug app is already running, or its process state cannot be determined.
  Start the host first, launch Flutter second, and reuse that host session.
  This avoids the demonstrated ownership conflict; it does not prove all
  native hot-restart races are fixed. Snapshot and readiness commands remain
  available while the app runs.

## Repair under validation

- Keep the physical scanner suspended for the full Libre connection lifetime.
  Keep recording heartbeats current without declaring NFC readiness. Resume
  scanning only after confirmed disconnect cleanup; uncertain cleanup blocks
  further connection attempts in that process.
- Permit one recovery after an acknowledged, subscribed connection
  delivered a CRC-valid packet and then physically disconnected. Require
  confirmed cleanup, the same reread bootstrap, a new fresh advertisement, and
  a fresh durable login count. In durable mode only, a replacement can earn
  another allowance after three fresh committed observations span two monotonic
  minutes, with contiguous and still-recent evidence. Errors, lone or repeated
  packets, history imports, and unacknowledged commits do not renew the budget.
- Inject the separate reference decoder only through the explicit full-UI
  bench entry point. Calibration is exact-receiver-bound, CRC-checked and
  stored independently under Android Keystore encryption outside backup.
  Capture restarts must not delete that protected copy. No capture-file search,
  host import, NFC setup replay or login-counter rollback is a fallback.
- Restore the existing protected receiver before discovery, without changing
  the sensor or making a connection automatically.
- Show a separate `Saved Libre 2` entry after a bounded read-only restore.
  It is not a nearby result or a connection claim. Explicit selection enters
  the fresh-advertisement wait; absent, unreadable, and stale restore results
  cannot start NFC, connect, or block other manufacturers.
- Wait for a fresh exact-target FDE3 advertisement for up to 150 seconds.
  Ignore stale, future, or timestamp-free advertisements and other sensors.
- Confirm scan cancellation, then use one physical connection attempt through
  every transport wrapper. Preserve normal AiDEX retry behavior.
- Keep setup inline. Generic help routes by the name on the sensor box;
  AiDEX/LinX help cannot start NFC. Only a Libre 2 choice opens its NFC flow.
- Display closed connection stages and readable failure messages. A packet
  with a valid CRC is not a calibrated glucose reading.

## Required release gates

| Gate | Current gap / required evidence |
| --- | --- |
| Calibrated readings | The private Android build now saves verified calibration and displays a decoded current bench estimate from live BLE. Exact-model expected-glucose conformance, production data-quality behavior, history/lifecycle integration, and broader persistence/recovery still need verification. This bench result does not validate body glucose. |
| License provenance | The pinned MIT LibreTools code supplies raw ADC and crypto, not calibrated glucose. The maintainer approved a separate GPL converter for private bench work; see ADR 0004 and the new package notices. Combined distribution and exact dependency/store compatibility still require review. |
| Production NFC | A default-off recorder-free Gen1 read-only backend and strict Dart routing are implemented. The same opt-in can now compose an existing receiver in Android debug only; release excludes it. Both need physical qualification. State-changing setup still requires the private recorder. Follow the [production integration map](libre2-production-integration.md); do not enable recorder/debug flags in a release. iOS NFC support is absent. |
| Lifecycle | Verify sensor-derived current age/lifecycle, warmup-to-active transition, expiry, stale-data suppression, and invalid-state handling. Historical activation and bootstrap lifecycle are not current-state evidence. |
| Recovery | Verify restart, reboot, update, range loss, Bluetooth toggle, counter exhaustion, uncertain writes, and Keystore loss without command replay or counter reuse. |
| Real sensor output | This expired sensor is on fruit for bench testing. It cannot validate wearable glucose accuracy. Require exact-model comparison with a trusted reference using an in-date sensor. |
| AiDEX/LinX | Keep existing behavior and run physical connect/history/disconnect/move checks on the final build, in addition to automated regressions. |
| Distribution | Clean reviewed source, full native command/CI checks, correct license notices, source-bound signed APK/TestFlight, release scope, and rollback plan. |

Gen2, Libre 3, and unsupported regional variants must not inherit a Gen1 support
claim. A working Android radio link does not satisfy the other release gates.

## Decoder source review

- [Pinned MIT LibreTools SensorData.swift](https://github.com/ivalkou/LibreTools/blob/d54b0883959420e5941ed293ec6b9ef2474b7ed3/Sources/LibreTools/Sensor/SensorData.swift)
  extracts raw glucose fields; it does not establish factory-calibrated mg/dL.
- [gluco-glance provenance](https://github.com/mohasi/gluco-glance#where-the-protocols-came-from)
  explicitly traces its factory tables to GPL xDrip via DiaBLE.
- [Package evidence boundary](../../packages/cgm_libre2/doc/evidence-boundary.md)
  records the existing pinned-source and privacy constraints.

This bounded review did not find a verified permissive calibrated decoder. It
does not establish that no compatible implementation route can exist.

## Verification checkpoint

After the saved-receiver/timing change, `make test-unit lint format-check`
passed: 900 unit/widget tests across all packages and the app, all analyzers,
and all Dart formatting checks. The full run exposed one timing-dependent
recorder-rotation test; it now waits for confirmed status writes instead of
arbitrary event-loop turns. No production publisher change was required.
`make test-integration tooling-check` passed the one discovered integration
test and the pinned tooling/workflow contracts. The separate pure Java NFC
runner passed all 11 suites, including the new unintegrated read-only
transaction. Independent reviews reported no unresolved P0/P1/P2 findings in
the reviewed timing, saved-receiver, transport, UI, and pure-read slices.

The updated private build was installed through `flutter run`, preserving app
data and receiver state. After unlock, a full app restart reused the existing
host session. Exact two-sample recorder readiness passed before saved-receiver
selection. The one explicit connection completed the handshake described above;
no activation or streaming-enable command was replayed. The UI correctly says
sensor data is arriving but glucose decoding is not ready.

These are local dirty-worktree checks, not a clean CI or signed release result.
No external release was published. All required release gates above remain
applicable; passing tests alone does not establish a functioning glucose reader.

### Decoder checkpoint

The next `make test-unit lint format-check` run passed 964 unit/widget tests,
all analyzers, and formatting, including 160 Libre protocol and 16 separate
decoder tests. All 1,023 factory indices match the pinned original Swift method
using synthetic values. Later focused calibration timeout/source-boundary tests
also passed. All 12 JVM suites and the offline Android Java compile passed.
Independent reviews of the converter, adapter, recovery, recording heartbeat,
and protected calibration slice found no unresolved P0/P1/P2 findings.
`make test-integration tooling-check` passed the integration and tooling gates.

The full-UI decoder entry point was installed and attached with `flutter run`.
The existing host capture session was reused; exact two-sample readiness
passed. The old calibration artifact was absent, so the read-only inline NFC
flow was opened for one fresh calibration tap. The streaming receiver and its
counter were preserved. This checkpoint does not yet claim a decoded physical
glucose sample or sustained streaming on the new build.

### Next-day bench continuation

On 2026-09-06, the old host recorder was no longer alive. The phone's private
traces were retained before a fresh Flutter session. The new scan failed with
the closed transport result `bluetoothOff`; enabling Bluetooth and restarting
the installed app restored healthy two-sample recording readiness. This does
not establish why Bluetooth had been disabled.

One explicit saved-receiver connection then completed discovery, acknowledged
login, and subscription. A private offline analysis of its first complete
packet with the earlier same-sensor calibration reported one accepted current
sample and no integrity or quality rejection. Neither raw data nor the
estimated value is included here. The analyzer did not import calibration into
the app, alter receiver state, or perform any sensor operation.

The phone still reported decoder unavailable: its protected calibration file
was absent. A previous successful explicit read and its volatile FRAM artifact
did not prove that the independent encrypted cache was saved. Source review
found no cache-deletion path; it did find that skipped/failed cache writes were
not distinguishable from success in the read result. Fresh persisted-only
verification is required after the next explicit read.

The same run delivered seven complete packets before Android reported a
physical link-supervision timeout (`status=8`) at 416.90 seconds. Scanning was
paused throughout that connection, so concurrent scanning is not necessary for
this observed failure. Local cleanup followed the physical callback, then the
single permitted recovery completed another connection, login and subscription.
Two further complete packets arrived. Private offline analysis accepted all
nine current samples with no integrity or sample-quality rejection. This is
one observed successful recovery, not a general sustained-operation guarantee.

The scanner exhaustion repair now terminates current and new logical scans
with a closed failure rather than leaving them waiting for the advertisement
deadline. Native calibration preservation now records `nfc.calibration.cache`
with only closed `outcome` and `reason` fields; `saved` requires completed
durable write and verified readback. The event does not change the completed
NFC read result or any sensor command. These changes require the next deployed
build and a fresh read for physical verification.

The updated private debug build was then installed through `flutter run` and
passed two-sample recorder readiness. Final local checks passed 993 unit/widget
tests, workspace analysis and formatting, integration/tooling contracts, 12
native JVM suites, and the affected Android debug build. Independent review
resolved the scanner terminal-state finding and reported no remaining
P0/P1/P2 findings in the scanner and cache-diagnostic slices. The read-only NFC
screen was opened for persisted-cache verification; that result is pending.

The next explicit read succeeded with lifecycle `active`, but the cache trace
reported `skipped/receiverMismatch`. Same-sensor private comparison found the
same UID/model and changed current patch bytes 4–5. The pinned reference
separates these roles: [current NFC patch and FRAM](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/NFC.swift#L310)
versus [initial streaming patch and decryption](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift#L133).
The cache had incorrectly required both complete patch values to be equal.
No mutation schedule or cause is inferred from this observation.

The repair stores both values separately, preserves the original Bluetooth
credential, requires exact UID and unchanged first four patch bytes, and
validates all three FRAM CRCs using the current NFC seed. Authenticated cache
format v2 retains strict v1 read compatibility. Synthetic adapter regression
accepts a correctly re-encrypted FRAM under a changed seed and rejects the same
FRAM under the wrong seed. This repair still needs a fresh physical cache save
and an in-app reading on the updated build.

The same tap exposed a separate UI handoff defect: Connect attempted to prepare
an already-confirmed streaming receiver and failed before RF. The repaired path
captures the completed explicit-read attempt token before stopping the reader.
A read-only native query binds that token to the current process, installation,
capture epoch, fresh CRC-checked same-sensor FRAM, and confirmed receiver. A
matching result reuses the saved Bluetooth setup, then enters the existing
fresh-advertisement connection path. Only a positively absent receiver permits
the original first-time setup; unknown, unreadable, mismatched or stale evidence
cannot repeat NFC enablement. A reuse proof is not a Bluetooth connection claim.

The combined patch passed 1,004 unit/widget tests, workspace analysis and
formatting, the discovered integration test, 13 native JVM suites, and Android
Java compilation. Independent calibration and UI/native reuse reviews found no
unresolved P0/P1/P2 findings. A final native presence check also verifies that
an absent receiver means ENOENT, rather than an unreadable or malformed file.
These remain local private-worktree checks, not release or clinical evidence.

### First live in-app estimate

The next successful explicit read identified Libre 2 with current lifecycle
`active`. Its private capture records `saved/verifiedReadback` for calibration;
the protected cache file exists in the active Android user's app storage.
The operator-selected Connect action reused the saved receiver. The trace
contains one NFC read and no activation or streaming-enable exchange.

The phone then displayed a numeric bench estimate with Connected. The saved
follow-up BLE trace contains one successful connection, discovery, acknowledged
login write, and notification subscription, followed by 15 notification
fragments (five complete packets). Private screenshots and trace snapshots
were retained outside Git. No value, identifier, or capture path is recorded
here. A full-process restart check follows this checkpoint.

At that checkpoint the driver published only the latest provisional sample;
history remained empty. The sample had a receipt timestamp, but the dashboard substituted
the bench warning for its normal timestamp detail. Decoded age and lifetime are
validated but not projected into session-life fields. These were integration
gaps, not evidence that packets were lost. The later policy below governs
received-history retention; it does not establish current lifecycle evidence.

The full Flutter quit/run check then restored the saved sensor, waited for a
fresh advertisement, completed one connection/login/subscription, and displayed
a new numeric bench estimate. The new trace contained three notification
fragments forming one complete packet within a 130.51-second recording window.
The protected calibration file remained present; the volatile NFC FRAM capture
file was absent. No new NFC tap or setup command was used. This verifies one
app-process restart with persisted calibration, not reboot, long-duration
streaming, clinical accuracy, or release readiness. Flutter debug attachment
and the existing private background recorder were left running.

Independent snapshot review confirmed changed Android/native/Dart/trace process
identities, the same application version and sensor target, and matching file
manifests. Installation metadata also changed because Flutter reinstalled the
debug build; the evidence is specifically quit/reinstall/run with retained app
data, not a hot restart. The new session contains zero NFC read, activation,
streaming-enable, or calibration-save events, and no failed BLE operation.

## Received-history and secondary-flow hardening

The 2026-09-09 continuation uses an isolated `codex/libre-readiness` worktree
from recorded source `164b170`. Earlier fixes are present in the shared
multi-sensor base; unrelated Yuwell work is not rewritten. This slice is R2,
owned by `@shroominic`. It excludes activation/enable replay, transfer, reset,
sensor replacement, production registration, and external distribution.

### Provisional-data policy

- Retain accepted samples and their existing source, sensor-minute, receipt
  time, and provisional fields in the existing backup-excluded restricted
  history store. This changes eligibility, not the serialized schema. The
  history store is not a new app-level encrypted database; receiver and
  calibration secrets use their separate encrypted native stores.
- Show received points in current and archived charts. Home uses normal
  connection status and current receipt time without bench/body warnings or
  repeated history banners. A `Data quality` row in Current sensor and archive
  details reports provisional/raw samples, including retained data while the
  connection is lost. No missing point is synthesized.
- Preserve the first accepted Libre minute/source across reconnect and restart;
  a duplicate must not shift a stored timestamp or replace its value. Sensor
  receipt time minus its minute counter is not verified lifecycle evidence.
  Do not derive a Libre start/expiry or retire its saved receiver from that
  calculation, nor from the age of its last received point.
- Exclude provisional and raw-source points from wellness metrics, summaries,
  AI aggregates, Apple Health, and numeric live notification/Watch payloads.
  A genuine warmup countdown remains available without early glucose values.
- Do not apply a previous sensor's local display scale/offset to provisional
  or raw values. Preserve the saved preferences and unit conversion. Hide
  sensor-calibration controls when the driver does not declare that capability.
- Explicit archive-file export retains those points and their disclosed quality
  fields. It remains separate from blood-glucose export to Apple Health.

This policy makes received history inspectable; it does not validate the
underlying measurements. The app has no person/fruit placement mode. Physical
test conditions belong in the evidence record, not a runtime branch; data
quality remains a separate driver-reported property.
No production eligibility flag is added. The existing retention/delete-all and
physical validation gates still apply. Rolling back to the previous app may
hide or stop adding these points, but must preserve the stored blobs and native
receiver/counter state.

### Setup and cleanup

Bluetooth discovery remains the primary inline flow. Model-specific help is
secondary, and only an explicit Libre 2 choice starts the NFC flow. Read proofs
expire locally before the native deadline; stale proofs need a fresh read.
Saved and nearby Libre selections explicitly disable the generic activation
permission; only the separate authorized NFC transaction can request activation.
Proof-only retry requires no sensor-write attempt and confirmed cleanup.
An uncertain sensor write or cleanup cannot be made retryable by closing a
sheet. Both connection error surfaces block Retry/Choose another when cleanup
is uncertain and ask for a full app reopen instead.

The remaining publication gates above are not waived by these repairs.

### Automated and phone checkpoint

The final `make test-unit lint format-check` run passed 1,077 tests across all
eight packages/app targets, all analyzers, and formatting. The discovered
integration test and `tooling-check` passed. All 15 Libre native JVM suites
passed; the hardened store also compiled against Android API 28 and API 37.
Independent reviews found no unresolved P0/P1/P2 issue in these changed slices.
These are local-worktree checks, not clean CI, a full `make check` result, or
approval for a signed release.

The Pixel debug app was updated through `flutter run`, retaining app and
receiver data. The first check found Bluetooth off and a failed scanner. After
Bluetooth was enabled, a full debug-app process restart restored exact
two-sample recording readiness. The existing host session was reused, not
restarted alongside the app.

Physical review also found a saved-receiver advertisement-timeout dashboard
with no Retry button. Its closed Libre error did not use the AiDEX-oriented
`BleFailure` metadata required by the old UI predicate. The repaired predicate
uses Libre terminal state and its explicit manual-recovery policy. A widget
regression failed before the fix and passed after it; the updated phone showed
enabled Try again/Choose another controls. Cleanup uncertainty remains
restart-only. One observed Try again action entered fresh-advertisement search,
with activation disabled and no NFC setup replay.

That attempt connected and received four complete packet groups. Independent
review verified the first snapshot's Connected state, two chart readings, and
provisional label; a later private storage check found three timestamped,
provisional points. The later trace snapshot had twelve fragments forming four
complete packet groups, but its screen showed another app, so that screen is
not chart evidence. One connection failure occurred before the successful
attempt; its closed `sensorPossiblyInUse` classification does not prove another
phone held the sensor. There were no failures after that successful connection
in those snapshots, and no NFC commands or calibration writes.

A full Flutter quit/force-stop/reinstall/run then restored four chart readings
before receiving any new packet. Independent review confirmed new native,
Android, Dart, and BLE process identities, matching manifests, Searching, a
blank current-glucose value, and the provisional notice. The app did not
present retained history as a current live measurement. This proves one
retained-data process restart, not a phone reboot or signed-app migration.

The new process then connected and the dashboard reached nine readings.
Private comparison found every previously checked stored point unchanged,
including its receipt time and quality fields. The normal Settings Disconnect
action subsequently archived eleven received points and cleared the selected
sensor. Every point checked before disconnect was present unchanged in the
archive; the protected receiver and calibration files remained present.
This is local BLE disconnect and history archiving, not Libre unbind/transfer.
Explicit Disconnect ends the local recording segment: its points remain in
Previous sensors. Reconnecting starts a new active segment, whereas ordinary
link recovery and app restart retain the active segment on the home chart.
Selecting Saved Libre 2 then completed another connection and delivered a new
active point, without an NFC tap. A private archive comparison after reconnect
confirmed all eleven archived points were unchanged and the active selection
was saved again. This does not download missed intervals or merge a deliberately
ended local segment back into the current chart.

Independent native review verified the restart connection and deliberate
disconnect snapshots: all sixteen files in each manifest matched, seven
complete packet groups arrived before local disconnect, and both subscriptions
were cancelled before the successful local disconnect. No physical-disconnect
callback triggered it. No NFC command or calibration write appeared in either
snapshot. The radio/session evidence and app history checks are complementary:
packet-group counts in one process are not a count of all retained app points.

The final independent reconnect snapshot verified two new complete packet
groups and two active chart readings after the explicit Saved Libre action.
Both connections used the same target. Across that process, nine complete
groups arrived through two successful connections, with one successful local
disconnect and no BLE failure or physical-disconnect callback. Its sixteen-file
manifest matched, and there were zero NFC commands or calibration writes.
The final Dart-only activation-permission guard was applied by Flutter hot
reload, not hot restart. The existing app process and host recorder remained
running; the guard has focused saved/nearby Libre and AiDEX/Yuwell regression
coverage. No activation or setup replay was used to test that policy change.
Independent continuity review then confirmed the same process and installation,
an exact-prefix trace, advancing healthy recorder clocks, and two additional
packet groups. The dashboard showed Connected with four active readings.
No reconnect, login write, disconnect, NFC command, or calibration save occurred
across that hot reload. The scanner remained suspended for the active BLE link.

### Receiver-store hardening

The receiver store now reports absence only after a native `ENOENT`. Reads
use `O_NOFOLLOW`, descriptor metadata, regular-file and owner checks, exact
`0600` permissions, a bounded size, exact read length, and confirmed close.
Denied, linked, malformed, growing, truncated, and uncertain reads fail closed.
Encrypted writes use exclusive random staging, descriptor checks, fsync,
atomic rename, and directory fsync. Failure after rename never restores an
older journal or counter; failure before replacement only discards that
operation's staging file. The pre-existing prepared-only abort contract is
unchanged. No reset or sensor command is added.

The encrypted envelope, Keystore alias, receiver filename, journal schema, and
counter semantics are unchanged. Synthetic file-policy tests and Android API
28/API 37 compilation passed. This is not yet physical migration/reboot proof.

### Sensor-details quality presentation checkpoint — 2026-09-09

The home screen now uses normal connection status and reading time. The
bench/body warning and repeated history banners are removed. Current sensor
and archive details instead show `Data quality` as `Provisional readings`,
`Raw sensor data`, or `Provisional and raw readings`; stable-only data has no
quality row. This describes reading provenance, not where a sensor is placed.
The earlier phone screenshots and notice descriptions above remain historical
evidence of their builds, not the current presentation.

The focused presentation, home-widget, and archive-feedback suites passed 72
tests. They verify normal Connected/value/time display, details-only quality
labels for ready/error/reconnect and archived data, and omission for stable
data. Analysis, formatting, and diff checks passed. This is focused local
verification, not a new full-workspace result. Independent review subsequently
passed all 533 app tests plus app analysis and formatting, with no P0/P1/P2
finding in the presentation slice.

The change preserves `isDisplayProvisional`, source fields, received-history
retention, explicit archive-export quality columns, and exclusions from
wellness/AI aggregates, Apple Health, and numeric live notification/Watch
payloads. It adds no sensor command, placement-dependent branch, new decoder
validation, sensor-support claim, license exception, or release approval.

A separate read-only phone check captured the existing connection error with
eight retained readings. The bound trace recorded Android connect error 133
before service discovery/login, with no unknown login write. The diagnostic's
`sensorPossiblyInUse` category is not proof of another receiver. The app's old
debugger connection had ended; a current-process device VM URI allowed attach
without restart. Source hot reload was then rejected because the running
`CgmSessionInfo` layout differs from this branch. The new presentation is not
installed on the phone. No app restart, sensor retry, NFC operation, reset,
bond removal, or data clearing was performed for this checkpoint. Connection
recovery and physical verification of the new UI remain open.

### Guarded debug update and connection diagnosis — 2026-09-09

After explicit restart approval, a fresh private pre-restart snapshot was
saved. Independent trace review found no scan/connect overlap: the failed
attempt followed a fresh target advertisement and failed with Android 133
before discovery or login. The pinned Android transport closes its GATT handle
before publishing this disconnected failure. This does not establish the
underlying native failure cause or justify bond removal or automatic retries.

The driver now retains closed pre-login transport diagnostics. Only the exact
known operation/kind/code combination becomes `androidGatt133`; arbitrary
codes and native text are not copied. Ten new regressions bring the focused
driver suite to 103 passing tests. Analysis, formatting, diff checks, and an
independent review passed with no P0/P1/P2 finding. Retry authority, counters,
sensor operations, decoder policy, and user-facing error text are unchanged.

The phone's installed debug certificate matched the local debug key and build.
Flutter then built and installed the updated debug app for the existing Android
user using replacement installation. A temporary, independently tested ADB
guard blocked Flutter's uninstall/data-clear fallback; no uninstall, app-data
clear, sensor reset, unpair, or NFC operation was performed. The build includes
the new presentation and earlier model/native changes. The later diagnostic
slice has local test evidence but no confirmed phone deployment yet.

The new process started, but Flutter's service-protocol connection failed.
A direct attach also failed. Android reported the screen locked, and the user
was asked to unlock it. Some read-only ADB queries stalled. At this checkpoint,
the new screen, retained point contents, fresh recorder binding, and restored
live notifications have not been verified. Installation success is not a
connection fix or release-readiness claim.

### Recorder-free reader hardening and local checks — 2026-09-09

The default-off Android read-only NFC backend now has exact native capability
routing, foreground/attempt ownership, a 120-second read deadline, an
eight-second uncertain-cleanup watchdog, and closed lifecycle events. It cannot
activate, enable streaming, expose receiver credentials, or return a reusable
handoff proof. Existing private receiver/capture state blocks this backend;
the current sensor container was not cleared or migrated to test it.

Independent review and regressions closed late capability/disposal dispatch,
stale queued events, partial native reader-start failure, late read-result
revival, and persistent lease cleanup gaps. Before any RF, acquisition syncs
the exact owner and its containing directories. All fallible release checks
precede exact-owner deletion; a partial delete retains a restart blocker.
These guarantees are detailed in the [integration map](libre2-production-integration.md).

The home screen now suppresses stale, untimestamped, non-finite, and raw values
without removing retained history. Its age-dependent presentation updates
without a new notification. Connection progress uses the actual driver/stage,
and compact/large-text setup has regression coverage. Source-quality and
Health/live-surface gates are unchanged.

The full local `make check` completed successfully: 1,168 unit/widget tests
across the eight targets, the discovered integration test, all analyzers and
format/tooling checks, Android and web builds, the fail-closed Android release
signing check, unsigned iOS and macOS preview builds, eight iOS native tests,
and two macOS native tests. The final native durability additions were then
independently checked with all 18 JVM suites, API 28/API 37 Java compilation,
tooling checks, and a fresh opt-in Android build. The packaged manifests were
inspected: the normal reader flag is false, the opt-in flag is true, and NFC
hardware is optional. The debug recorder and read-only backend remain mutually
exclusive. These are dirty-worktree checks, not clean CI or signed artifacts.

The connected Pixel was unlocked and its existing screen showed a sensor-not-
found error with eight active readings. The old host recorder was no longer
alive. After preserving a private history baseline and stopping only the debug
app process, a new host capture was started and the app was updated through
guarded `flutter run`. The guard was configured to reject package-removal/data-clear fallback;
the private debug entry point retained the existing receiver path and kept the
new read-only backend off. All nineteen stored points across the active and
archived segments, plus metadata, were unchanged after replacement install.
The app process started, but the phone was locked at the post-update check and
Flutter service attachment failed again. Lock state is not a proven cause of
the HTTP failure. Android reported no charging source despite
an active USB data connection, so its existing plugged-in stay-awake setting
did not establish an unlocked session. The user was asked to unlock and keep
the sensor nearby. No sensor retry, NFC operation, bond removal, reset, or
receiver migration was used for this checkpoint. The new host logcat process
also failed its later identity/liveness check, so continuous host recording was
not established. Current-build streaming and
physical reader validation remain open; a successful install is not that proof.

A subsequent attach used the current process's original device VM URL, a fresh
ephemeral forward, the matching entry point/defines, and `--no-dds`, without
restarting or reinstalling. It also failed with an HTTP connection closed
before response headers. This rules out neither a device/forward problem nor a
service problem; disabling DDS and correcting endpoint selection were
diagnostic isolation, not a confirmed fix. The debugger is not attached.

### Current timing evidence and next boundary

The pinned [BLE parser](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift)
uses bytes 40–41 of the decrypted Gen1 payload as elapsed sensor minutes. The
pinned [FRAM parser](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre.swift)
uses bytes 316–317 for age, 326–327 for maximum life, and byte 4 for lifecycle.
These fields support sensor-relative timing and lifecycle at the time of an
NFC read. They do not supply a UTC activation timestamp, a continuously current
lifecycle, or a dynamic warmup-duration field. Packet CRC validates integrity;
it is not cryptographic authentication or glucose-accuracy validation.

The next bounded implementation is an independent MIT timing-only parser over
the existing CRC-validated payload types, separate from GPL glucose conversion.
It must keep packet age, observation freshness, and FRAM lifecycle-at-read
distinct; handle replay/reconnect/restart; and test warmup/error/no-glucose
packets without publishing glucose. Do not synthesize a UTC start time, force
unknown lifecycle to active, infer hardware backfill, or retire/delete receiver
state from age alone. Physical exact-model warmup and expiry evidence remains
required before a production support claim.

### Timing, history, and receiver progress — 2026-09-10

The MIT timing parser is now implemented and consumed by the live driver.
CRC-validated BLE age advances even when glucose conversion is unavailable or
rejects a sample; a decoder must agree with that age. Repeated/regressed minutes
cannot refresh the ten-minute observation deadline or become new readings.
Recovery retains this in-memory frontier. FRAM age, lifetime, and lifecycle are
separate read-time observations, not current state loaded from factory storage.
The shared UI can display fresh sensor-relative age without synthesizing UTC
activation. Nominal elapsed-only expiry does not automatically archive or
remove the selected sensor. Protected replay-frontier persistence across new
sessions/processes and fresh FRAM integration remain required.

Independent review found and fixed final-reading loss at Disconnect, cancelled
debounce loss before reconnect, stale queued writes replacing newer history or
recreating cleared history, a failed-flush latch after successful explicit
clear, and wrong-target history on uncertain cleanup. Writes and history
deletions now share a queue; saving failures retain in-memory data and block
reconnect. New regressions reproduced the data-loss/order faults before fixes.

Recorder-free native and Dart saved-receiver components now enforce exact
ownership across connection, counter reservation, outcome marking, and close.
They remain unregistered in the normal app and were not exercised against the
phone's protected receiver. The [receiver contract](libre2-receiver-integration.md)
records the closed interface, bounded late-reply behavior, and crash-recovery
gap. No new enrollment, receiver migration, activation, reset, bond removal,
or production distribution was performed for this slice.

The connected Pixel's Bluetooth was off. The current app incorrectly reported
the saved sensor as not found; the host capture stayed alive and native storage
was healthy, but the scanner reported an error. Bluetooth was enabled through
Android's system command. The driver/UI now distinguish typed Bluetooth-off,
permission, adapter-unavailable, and scan failures from an actual discovery
deadline. Those cases passed synthetic tests; this is not yet a new physical
streaming result. The initial full validation run stopped advancing in the
home-aging widget test and was interrupted, not counted as passed. A fresh
complete baseline and current-build phone evidence are required below.

The fresh full `make check` completed with exit zero: 1,239 unit/widget tests,
one integration test, analyzer/format/tooling checks, Android and web builds,
the fail-closed Android signing guard, an unsigned iOS build, eight iOS native
tests, a macOS preview build, and two macOS native tests. All 19 standalone JVM
suites also passed. The stalled widget harness was corrected to let its
fake-clock UI work and real storage event queue both advance; no production
persistence or close barrier was relaxed. Independent review found no open
P0/P1/P2 issue in the bounded timing, history retention, typed scan failure, or
unregistered receiver components. These are local dirty-worktree results,
not signed-release or hardware conformance evidence.

The subsequent guarded `flutter run --no-dds` installed the private debug entry
point and attached successfully. Exact two-sample current-process capture
readiness passed using the already-running host session. The saved receiver
restored without NFC or bond changes. One fresh-advertisement attempt completed
connect in 219 ms, service discovery in 1,018 ms, the login write in 123 ms, and
subscription in 148 ms. The subscribed snapshot had six notification fragments,
no BLE operation failure, healthy recording, and the scanner suspended while
connected. The UI displayed a new reading and nominal remaining life from fresh
sensor-relative timing. A private before/after comparison confirmed all 19
previous stored readings unchanged; a later check contained three additional
saved readings. This verifies that private receiver path on the current build,
not the new unregistered receiver components or wearable accuracy.

The initial durable timing design identified a point-loss window:
committing an observed-minute frontier before debounced history can suppress a
point after a crash without ever having saved it. Use an atomic exact-receiver
frontier and optional normalized-reading outbox, with acknowledgements only
after durable app history writes. Rejected/warmup observations have no reading
entry. Replayed entries are historical at their original receipt time, never
fresh current output. Bound the queue and fail closed on uncertain persistence.
Legacy receiver records cannot recover rejected ages from accepted history;
migration needs an explicit reviewed baseline, not an inferred zero frontier.
That outbox design was not implemented. The subsequent atomic-history slice
below uses one app-owned envelope instead, avoiding a second commit/acknowledgement
store while retaining the same completed-commit requirement.

### Background and explicit-disconnect faults — 2026-09-10

The subsequent physical check did not establish sustained background operation.
An 88-second history comparison retained every original record and added one
point, but Android later froze the background app process. Private native logs
show pause/stop, process freeze, an approximately 70-second recording gap, then
thaw and a native status-8 link supervision timeout. Notification fragments
delivered after thaw can be delayed callbacks; they do not prove radio receipt
during the gap. The connection service had been coupled to glucose publication
eligibility, so provisional output did not keep it running. The implementation
now separates status-only connection ownership from numerical notification
eligibility; new hardware verification of that fix is still required.

A bounded recovery succeeded, followed by another status-8 timeout while the
app was foreground with advancing capture. That second timeout is not explained
by process freeze. In both cases the capture scanner resumed only after native
disconnect and transport close; this evidence does not support blaming a
simultaneous scan for those drops. No bond removal, receiver reset, speculative
counter change, or NFC operation was used to recover.

An explicit local Disconnect preserved all 25 then-stored readings: the 14
active readings became an exact-target disconnected archive and the previous
11-reading archive was unchanged. However, a later automatic connection still
started. The controller had detached the old session before clearing its saved
selection, allowing periodic freshness work to enter that gap. Pending driver
results also lacked an attempt-generation fence. The controller fix adds an
awaited teardown barrier and exact late-result ownership; synthetic regressions
cover the race. Its physical no-reconnect check remains open until the updated
build is installed.

The archive summary also showed zero readings despite retained provisional
records. It counted wellness-eligible data instead of stored history. A separate
stored-reading count now covers retained arrays without changing quality,
wellness, or export eligibility. The final pre-update private snapshot contained
32 stored readings across three history arrays. These observations describe the
private debug receiver path only; none closes the production gates above.

The shared service repair uses a fixed, status-only Android foreground
notification for owned connection work. It takes no sensor identity or glucose
payload and does not request notification permission. Existing numerical
publication and iOS eligibility are unchanged. Native startup success requires
an actual foreground-service start within a monotonic deadline. Process-local
ownership epochs reject delayed intents; null/sticky restart cannot recreate
ownership from a persisted notification. Dart orders commands and may drop
superseded starts, but every awaited stop executes its own native stop and
reports its own failure. Reconnect keeps service ownership across internal
close/open. Independent review found the superseded-stop bug and a delayed
native-timer gap; both have red-before-fix regressions.

Controller teardown now invalidates connection generations before asynchronous
cleanup, owns late driver handles, and blocks new work when cleanup cannot be
confirmed. Disposal cannot attach a late result. Manual sync rechecks exact
session ownership after live refresh. Activation confirmation is exposed only
after read-only probe cleanup, remains exact-target-bound, and is cancelled by
replacement/cancellation. Local successful Disconnect also clears the home
connection intent. The focused controller and setup suites passed 85 and 60
tests; the integrated app suite passed 622 tests. A later full check stopped on
two test-only analyzer style findings; those were repaired before rerunning.
These test results do not replace final native compilation or phone evidence.

The repaired full `make check` then passed: 1,264 unit/widget tests, one
integration test, all analyzer/format/tooling gates, 20 Libre/service JVM suites
and the two Yuwell JVM suites, Android debug and web builds, the fail-closed
release-signing guard, unsigned iOS build and eight native tests, plus the
macOS preview build and two native tests. The full unfiltered app command also
passed 622 tests (including its integration test). These are local worktree
results; no signed artifact was published. All 32 current readings were copied
privately as the immediate pre-update baseline before a guarded Flutter
replacement run. No data-clear or uninstall fallback is permitted.

### Combined-build phone checkpoint — 2026-09-10

Guarded `flutter run --no-dds` compiled the private debug target in 13.5 seconds,
replacement-installed it in 4.5 seconds, and attached with debug controls. A
private comparison confirmed all 32 original readings unchanged. Android
reported the connection service present with `isForeground=true` during the
saved-receiver attempt and the explicit retry. No notification consent change,
NFC action, bond removal, receiver migration, or reset was performed.

The first connection reached native connected at process trace +62.421 seconds
and started service discovery at +62.462 seconds. At +65.979 seconds, the native
callback reported status 19, `REMOTE_USER_TERMINATED_CONNECTION`. Native
unregister/close preceded Dart cleanup (+66.037 to +66.038 seconds) and scanner
restart (+66.039 to +66.063 seconds). The app's foreground service stopped at
+66.049 seconds, after the link failure. No login write, notification
subscription, or new reading occurred. Unlike the earlier status-8 background
fault, the process did not freeze and recording continued without a gap larger
than two seconds. The remote termination reason does not establish why the
sensor ended the link. The explicit UI retry exhausted its fresh-advertisement
wait without a second physical connect. Do not label that result a successful
stream or fix it by replaying setup commands.

Local Disconnect was then tested from this failed, already-closed connection
state. Exact-target verification confirmed that its seven retained readings
became one disconnected archive; the two previous archives and all 32 readings
were unchanged, and the selected-sensor pointer was removed. Home returned to
Connect and displayed `32 stored readings`. Android reported no connection
service. Two exact process/build-bound snapshots 114 seconds apart had
advancing recorder clocks/sequences and no additional connect, discovery,
login, or subscription operation. This verifies the observed idle/retry race
repair and archive count, not a new live-stream Disconnect or sustained
background radio test. Flutter remains attached and private capture remains
healthy. The radio fault and the publication gates remain open; no release was
published.

### Atomic observation history and opt-in receiver composition — 2026-09-10

The next source slice connects the recorder-free receiver components to an
opt-in Android debug registry alongside unchanged AiDEX. It preserves exact
capabilities, native backend exclusivity, lease/counter ownership, and separate
saved-receiver versus NFC enrollment authority. Default/release builds still
omit Libre. The opt-in path injects no decoder. Main bootstrap initializes one
restricted history repository before platform composition and shares it with
both the controller and Libre observation adapter.

The durable history design now uses one atomic envelope, not a native outbox.
It stores the observed-minute frontier and optional accepted reading together
before live publication. Loads restore history only. Rejected/warmup minutes
still advance the frontier, while repeated minutes cannot refresh timestamps
or freshness. A bounded queue uses packet receipt time, not write completion,
for the observation deadline. Any failed or timed-out dispatched load/commit
quarantines the driver; RF cleanup still runs. The repository separately blocks
an uncertain identity against stale-cache rewrites and retains confirmed-only
display data. The controller keeps selection on an uncertain disconnect and
preserves the closed storage failure code when connection-time loading fails.

Normal Disconnect retains the active observation envelope after archiving.
Clear history writes a replay tombstone; late driver/controller snapshots cannot
restore deleted readings or current data. Before the first bound envelope,
migration unions the active legacy list and existing archive references for
the exact saved bootstrap, preserving their first receipt and source flags.
That maximum known minute is only a lower bound: previously rejected minutes
cannot be recovered. Bound envelopes never reimport archive data. This matters
on the Pixel, whose earlier Disconnect left 32 readings in three archive arrays
and no active history. A new private pre-update copy verified all 32 unchanged.
See [ADR 0006](../architecture/adr/0006-atomic-libre-observations.md) and the
[downgrade limits](../compatibility.md).

Short all-history charts now choose clock labels from their actual visible
span; archive summaries say saved sessions rather than separate sensors.
Focused controller/privacy/receiver tests passed before the full build check.
These source results do not establish sustained RF reception or release support.

During this work the existing Flutter debug link and host logcat process ended.
The app remained running. A read-only export verified the same installed build,
PID, Android user, native/Dart capture identities, and a healthy advancing
recorder. Its exact committed prefix contained 1,732 contiguous events with a
matching receipt and the previous prefix unchanged. Across 2,818 seconds after
the sole disconnect, 46 exact-target FDE3 advertisements appeared, with no new
connect, write, or notification. Thus the target advertised again while the
explicitly disconnected app stayed idle. The old native status 19 matches the
app PID and disconnect time; the nearby native line lacks a direct address.
Host log continuity is incomplete and is not claimed as continuous capture.

The completed full `make check` for this slice passed 1,341 unit/widget tests
(134 core, 17 BLE, 26 Flutter BLE, 84 AiDEX, 266 Libre, 33 separate GPL decoder,
106 Yuwell, and 675 app), one integration test, tooling/format/analysis, Android
and web builds, fail-closed Android signing, unsigned iOS/native tests, and
macOS preview/native tests. The opt-in recorder-free Android debug configuration
also compiled separately with normal `lib/main.dart`; it was not installed.
An initial full-check attempt found one test-only tearoff lint; the corrected
full rerun passed. No release or signing credential change occurred.

An isolated host test then exercised the real private history backup using a
synthetic binding digest only for migration mechanics. All three archives and
32 readings preserved their instants, source, and provisional flags. The
frontier matched the known maximum; archive/backup bytes were unchanged;
repeated minutes were rejected; and a bound clear could not reimport archives.
This does not validate the actual UID/model binding, which belongs to the driver.

The old idle app process was stopped without clearing data. A fresh host capture
started while the app was stopped; the incomplete old capture was preserved.
Guarded Flutter replacement-installed the private decoder target and attached
with debug controls. Post-install comparison verified all 32 original readings
unchanged. The Pixel locked during this update, so foreground recorder readiness,
real binding migration, fresh connection, and UI visual checks await unlock.
The existing all-charging stay-awake mask remains enabled; no lock bypass was used.

### Archive, clear, and warmup selection review — 2026-09-10

Review reproduced cumulative Libre archive duplication: a no-new-data
disconnect could inflate a stored count from 32 to 52. Delta-only archiving now
subtracts exact-bootstrap archived observation identities, skips an empty delta,
and leaves existing blobs unchanged. Same-clock, rollback, and orphan collisions
allocate an unused opaque segment discriminator. Aggregate counts deduplicate
older overlaps within each bootstrap, never across sensors. Unknown manifest,
related blob, or nested variant data is preserved and reported unavailable;
an unrelated sensor's Disconnect cannot silently normalize it.

The shared repository rejects a legacy clear when the exact receiver has
archive-only readings but no binding for a replay tombstone. A controller clear
also cannot report success during a pending Disconnect/archive write. Fresh
new committed Libre timing can retain selection during warmup or decoder-free
reception, without changing numeric readiness. Initial and streamed snapshots
use the same exact-identity predicate; stale, repeated, failed, pending, or
cancelled evidence cannot establish a new selection.

Focused verification passed 148 driver tests, 46 repository tests, 11 archive UI
tests, and 112 combined controller/Android-lifecycle tests. An isolated real-data
copy again preserved all 32 original readings, instants, source/quality flags,
and archive bytes; its grouped count was 32 and no-new-data delta was zero.
That copy used a synthetic digest for migration mechanics, not real binding
validation.

The first canonical full check of this review slice found one Android lifecycle
regression. A noncanonical test fixture exposed a real error branch: after
confirmed RF closure, archive failure skipped waiting for a queued native start
to stop. Disconnect now awaits that shutdown even when it must retain the app's
selection/history/error, and invalidates the cached native background identity
for the next explicit connection. Unknown RF/observation ownership handling is
unchanged.

The frozen-source canonical rerun passed all 1,372 unit/widget tests and one
integration test, plus native checks, the fail-closed Android release-signing
guard, Android and web builds, and unsigned iOS and macOS preview builds.
Flutter then completed a hot reload into the attached
debug app. A read-only comparison of the latest phone backup with the original
backup confirmed that all three archives and their 32 original readings remain
unchanged. The phone is now unlocked. Foreground recording, migration with the
actual receiver binding, and fresh live connection/streaming remain unverified
at this checkpoint. These source checks and backup comparisons do not establish
new RF or NFC behavior, authorize bond changes, or establish release readiness.

### Bound history migration and discovery attempt — 2026-09-10

After unlock and a successful capture-readiness check, the operator started one
explicit saved Libre connection without NFC. The real app's observation load
created a bound history envelope before radio connection. Independent read-only
verification of the resulting backup passed the frozen repository's strict
parser and preserved all 32 original observations, including their receipt
instants, source, provisional flags, numeric/raw fields, and qualifiers. The
three original archive blobs and manifest remained byte-identical. The migrated
frontier equals the maximum known accepted minute with `legacyLowerBound`
provenance; it does not recover previously rejected minutes. The grouped archive
count is 32 and the no-new-data archive delta is zero. Verification performed
no writes, and both backup files and repository source remained unchanged.

This is evidence of migration through the real saved-receiver app path, not the
earlier synthetic-binding mechanics test. The independent check validated the
stored envelope binding and exact archive identity; it did not independently
derive a physical UID/security digest.

The final foreground capture was healthy, writable, and resumed, with 1,931
contiguous, receipt-matched events and a maximum heartbeat gap of two seconds.
Its process, build, native session, and BLE session matched the baseline. After
a bounded 150-second observation, the attempt showed the sensor-not-found UI. No fresh target
advertisement, connection, write, notification, or streaming was observed in
that attempt; the trace also contained no scan-failure event. A native service
start request was allowed, but service mentions alone do not prove foreground
startup. This does not establish a battery, receiver, or scanner root cause.
Migration preservation is verified; fresh reception and sustained streaming
remain open release gates.

### NFC history is separate from received Bluetooth history — 2026-09-10

Abbott's [Libre 2 history FAQ](https://www.freestyle.abbott/uk-en/support/faq/question-answer.html?q=UKFaqquestion-56)
describes a scan transferring up to eight hours of stored readings at
15-minute intervals. This was a missing feature at the start of this audit, not a
reason to claim the sensor has no backfill. Do not extend that model-specific
statement to other Libre generations or regional security implementations.

At that checkpoint, the native read transaction obtained and validated the complete FRAM,
but no NFC-history import consumes its ring records. The separate decoder
currently converts BLE packets, and the app adapter uses only the current
sample. Raw capture/calibration retention is not chart history synchronization.

The next implementation slice needs a fresh exact-sensor NFC read, a verified
ring/index/time mapping and conversion, and a separate atomic historical import.
It must merge missing points without refreshing live glucose, rewriting
Bluetooth first receipts, advancing or rolling back the live replay frontier,
or defeating clear tombstones. Sensor-relative historical timestamps must not
be relabelled as phone receipt times. Preserve receiver credentials, login
counters, leases, and existing NFC activation/streaming journals. Expose this
as an explicit Libre-specific history action, not another generic Connect or
activation action. Physical validation and source-quality/distribution gates
remain required before a support claim.

Pinned [DiaBLE ring parsing](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre.swift#L122)
describes 16 recent one-minute slots and 32 historical 15-minute slots. The
[LibreTools timing branch](https://github.com/ivalkou/LibreTools/blob/d54b0883959420e5941ed293ec6b9ef2474b7ed3/Sources/LibreTools/Sensor/SensorData.swift#L170)
describes delayed history and a boundary adjustment whose timestamp and sample
counter need explicit reconciliation before porting. Ring wrap, initial empty
slots, delay boundaries, CRC failures, repeated scans, and overlap need fixtures.

Importing only minutes below an existing BLE frontier is at most a limited
mechanics test: it does not fill the main outage case, where the sensor stores
new readings after the last Bluetooth packet. The complete design must permit
that historical import while keeping live-observation evidence separate. The
current envelope rejects readings newer than its observed frontier; review a
versioned contract rather than weakening this invariant incidentally. Clear
must cover imported history too. Old calibration memory must never be passed
off as a new scan to manufacture missing readings or current timestamps.

The bounded design review proposes a Libre-only version-two envelope, not an
implemented migration or an accepted replacement for ADR 0006. It would keep
the live observed-minute frontier separate from the last imported NFC scan age,
and retain immutable per-reading acquisition origin, first receipt, and timestamp
basis. Historical import may exceed the last BLE minute without supplying live
freshness or selection evidence. A separate conservative replay limit can use
both observed ages without calling an NFC observation a live BLE packet.

An import ticket must be issued before the fresh read and bind the exact
receiver, process/connection ownership, deadline, and clear revision. All
imports, live commits, clears, and archive reads share the existing atomic
queue. Clear must cover both observed ages and retained sample minutes; a late
ticket from before clear cannot restore data. Existing BLE receipts and
archives remain unchanged. NFC acquisition provenance must survive new archives.

The controller also needs a reviewed current-reading confirmation rule: its
present same-minute/source lookup must never substitute an NFC historical record
for a committed live BLE reading. Unknown legacy provenance cannot be upgraded
by inference. The receiver-bound NFC ownership path, ring boundary/quality
fixtures, capture-duration and clock-change limits, schema migration, and
import/clear/reconnect races must be settled and tested before this design is
wired to a phone. No implementation or NFC operation was performed by that
initial design review. The following source checkpoint supersedes its missing
parser/converter/storage status, not its hardware or release gates.

### Fresh NFC history foundation — 2026-09-10

The MIT parser now extracts up to 16 recent and 32 historical raw records from
the all-three-CRC-verified Gen1 FRAM type. It retains quality and temperature
fields, omits pre-start slots, and rejects the reference's ambiguous age/index
boundary rather than shifting a sample identity. The separate private GPL
decoder uses that same fresh image for coefficients and samples. Fresh warmup
state cannot produce active glucose; cached BLE calibration behavior is not
changed. Regional/generation support is not widened.

The native restricted handoff returns only the current explicit attempt's
fresh, exact-receiver artifact after foreground, capture, ownership, and
120-second checks. It never reads the calibration cache as fresh history.
Owned native and Dart byte buffers have bounded lifetimes. The Dart adapter
retains provisional/vendor quality, acquisition source, receipt time, and
sensor-relative sample timing; it does not produce a current-reading getter.

The repository now supports schema two on the first successful NFC import.
Until then, schema-one bytes remain unchanged. The live BLE observation age is
separate from the NFC scan age; a conservative replay barrier rejects older
live packets without turning NFC history into a live observation. Single-use
owner-bound tickets, clear revisions, timing limits, serialized writes, and
uncertain-write quarantine protect imports. New archive segments retain origin,
first receipt, and timestamp basis; old archives are not rewritten. The driver
rejects inconsistent advanced-commit acknowledgements. Display reads retain
the last confirmed history during a quarantined write instead of throwing.

The app's explicit history pause installs its guard before awaiting Bluetooth
close, drains native background starts, and preserves the exact selection and
receiver. Scans, reconnects, and foreground refresh cannot compete with that
pause. Disconnect returns a busy error until the read owner stops NFC. A
failed stop cannot be upgraded by a late successful release. Releasing a pause
does not reconnect automatically or publish historical values as live glucose.

Verification completed for this source foundation: 88 raw-parser tests,
46 GPL decoder tests, 28 fresh-reader/adapter tests, 100 repository tests,
153 driver tests, and 120 controller persistence/lifecycle tests. These are
overlapping focused suites, not an aggregate full-suite total. Scoped analyses,
the standalone Java tests, and the Android debug Java compile passed. Reviews
found and fixed fresh-warmup acceptance, oldest-ring validation, malformed
commit acknowledgements, and quarantined display access.

### Private NFC history action integrated — 2026-09-10

The [coordinator](../../openhealth/lib/src/libre_nfc_history_sync.dart) now
pauses the exact selected receiver before starting one explicit NFC read. It
captures the completed attempt identity, confirms native stop, decodes the
fresh restricted evidence, and imports through the same schema-two repository
used by the controller and driver. Cancellation revokes the import ticket and
reader result. The pause remains held through final session disposal; failed
or timed-out cleanup blocks new connections and cannot be upgraded by a late
completion. No activation, streaming-enable, transfer, or reset command is added.

The [inline settings panel](../../openhealth/lib/src/libre_nfc_history_pane.dart)
shows scan progress and a truthful imported-reading count only after cleanup.
Opening settings does not read a bootstrap or start RF. Leaving the flow or
backgrounding cancels it. Disconnect and Replace are disabled while the pause
is held. Neither flow completion nor foreground timers reconnect automatically;
the user must explicitly resume Bluetooth.

Main now passes optional history tools to the selected Libre settings pane.
The factory exposes them only when the private Android capture driver and
decoder are configured. Normal, web, and recorder-free paths remain
decoder-free and do not expose this history action. There is no calibration
cache or capture-file fallback for fresh evidence. The four new factory/source
guards cover default-null tools, lazy construction, decoder-free imports, and
the single initialized repository owner.

Focused verification passed 32 coordinator tests and 22 panel widget tests,
with clean scoped analysis. The final broad verification passed 1,618
unit/widget tests, one integration test, Android JVM checks, and Android, web,
unsigned iOS, and macOS preview builds. Tooling, formatting, all workspace
analyzers, and the Android release-signing failure guard also passed. The
private NFC-enabled Android debug entry builds separately. iOS/macOS native UI
tests were not rerun. Installation, an actual fresh NFC import, and physical
timestamp comparison remain pending: the Pixel disconnected from USB before
the update. A pre-update private backup retains all three original archives
and all 32 readings unchanged. No new NFC tap, sensor write, phone update, or
release is claimed by this source checkpoint.
End-of-life backfill, recorder-free qualification, sustained reception,
exact-model accuracy, and GPL/distribution gates remain open. Acquisition-aware
export was implemented in the subsequent source checkpoint below; its
repository/UI integration and broad validation are recorded in the subsequent
export checkpoint below. Retained capture
files are not a substitute for a new owned scan.

The final native review found a success-delivery ordering race: `metadataRead`
could reach Dart before the outer NFC callback cleared its active flag, so an
immediate fresh-evidence query rejected an otherwise valid read. A single-use
callback handoff now delivers success after buffer cleanup and callback drain.
The fresh-evidence guard remains strict. Three deterministic JVM regressions
cover the gated callback, failed cleanup, and reentrant/repeated completion.
All native JVM suites, the private Android debug rebuild, and a fresh full app
test run (845 tests including the integration test) passed after this fix. This
is software evidence, not a successful physical NFC import.

### Provenance-aware archive export implemented — 2026-09-10

The [immutable export model](../../openhealth/lib/src/sensor_archive_export_data.dart)
keeps every reading paired with its acquisition evidence through sorting and
isolate transfer. The repository reader resolves the exact persisted archive
manifest reference. It does not join active history, infer a first receipt, or
silently turn invalid provenance into a legacy export.

The [serializers](../../openhealth/lib/src/sensor_archive_export.dart) preserve
byte-compatible 13-column v1 output through the existing APIs. Data with
acquisition evidence uses additive 17-column v2 in CSV, TXT, and XLSX. The appended
columns are `export_schema_version`, `acquisition_origin`,
`first_received_at_utc`, and `timestamp_basis`. Legacy unknown receipts remain
blank; the reading's value source is unchanged. Sensor identifiers and raw
protocol frames are not added to the file. Output bytes are deterministic.

All 53 focused serializer tests passed. A separate 158-test run passed 43 strict
export-data tests, 100 existing repository tests, and 15 archive/home UI tests.
The actual CSV/TXT/XLSX UI path reads the shared file inside the injected share
callback; legacy output remains 13 columns. Corrupt archive tests cover list,
detail, and confirmation with no widget exception, temporary-file request, or
share call. Non-Libre opaque archive IDs and raw numeric ranges remain valid;
Libre-specific bounds do not restrict ordinary exports.

These end-to-end tests found an existing navigation defect: the share scope was
below Navigator and unavailable on pushed archive pages. It now wraps Navigator
through the app builder. Confirmation rereads the exact archive before sending
the complete immutable DTO through compute. Data-read errors show unavailable
feedback rather than an empty archive or a failed widget build.

The final broad check passes 1,706 unit/widget tests, one integration test,
Android JVM suites, all workspace analyzers, formatting, and Android, web,
unsigned iOS, and macOS preview builds. Tooling and the Android release-signing
failure guard pass. iOS/macOS native UI tests were not rerun; no desktop app was
opened. The private NFC-enabled Android debug entry also builds. This source
checkpoint does not claim a successful hardware NFC import,
a phone update, recorder-free qualification, expiry support, or release
readiness. Exact-model validation and GPL/distribution gates still apply.

### Sparse received BLE history — 2026-09-11

The private converter already decodes or rejects ten slots per CRC-checked
packet. The adapter now exposes the nine older slots separately from current
glucose. Six older trend positions use offsets 2, 4, 6, 7, 12, and 15 minutes;
the three history positions start at `((age - 2) ~/ 15) * 15`, then step back
15 and 30 minutes. The driver admits only these positions, omits rejected or
pre-warmup samples, and keeps valid history when the current value is rejected.
No new conversion formula or sensor command is added.

Accepted older samples use the original receipt minus their sensor-minute
offset and retain separate `bleTrend`/`bleHistory` origin. The repository commits
them with the packet frontier and optional current reading in one transaction.
Overlap preserves first acquisition; clear tombstones prevent restoration of
deleted points. Schema three permits BLE-only evidence with no NFC scan minute,
while schema two remains strict. Older storage and archives are not eagerly
rewritten, and newer state must not be downgraded. The 17-column export v2 keeps
the new origin values without changing value-source or provisional flags.

The shared `acquisitionRelative` data profile prevents activation or lifecycle
inference from mixed live receipt and receipt-minus-offset timestamps. These
older samples cannot create current glucose or live connection evidence.

Independent review found and fixed an acknowledgement gap when a prior sample
was outside the UI's bounded history. The driver now compares returned samples
against the full last-acknowledged store history or the exact newly supplied
candidate. Regression tests cover both an altered old-hole value and a valid
first acquisition outside the presentation window. Clear can legitimately omit
samples below the prior barrier; it cannot silently rewrite a retained sample.

Focused checks pass 405 protocol tests, 183 repository/export-data tests, 122
adapter/export/fresh-NFC/profile tests, and 113 controller/composition tests
(these groups overlap and must not be added). The controller regression verifies
BLE-only history reaches a provenance-bearing archive/export while current
glucose stays absent and the original three archive byte strings stay unchanged.
The final broad check passes 1,828 unit/widget tests plus one integration test,
Android JVM suites, all analyzers, formatting/tooling checks, and the Android
release-signing failure guard. Android, web, unsigned iOS, and macOS preview
builds pass. iOS/macOS native UI tests were not rerun; no desktop app was opened.
The separate `libre_glucose_debug_main.dart` Android debug entry also builds
with the existing private trace and Libre/AiDEX capture flags. No decoder
arithmetic, dependency/lockfile, receiver key, counter, or bond was changed by
this slice. Independent reviews have no outstanding P1/P2 findings.
The Pixel remains absent over USB: no phone update, new physical capture,
successful NFC import, or release is claimed.
