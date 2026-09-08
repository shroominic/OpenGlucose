# Libre 2 release readiness

Status: private Android bench validation, not ready for a stable sensor-support
claim. Accountable owner: `@shroominic`. Updated: 2026-09-06.

The current repair is R2 (Bluetooth connection and setup UX). It does not change
the already approved one-shot activation or streaming NFC command sequence.
Any production sensor command or external distribution retains its R3 gate.

## Current sensor-flow capability audit

This table describes the private Android Gen1 implementation. It does not
extend the normal release registry or establish compatibility for other Libre
generations, regional variants, or sensor firmware.

| Operation | Implemented behavior and remaining boundary |
| --- | --- |
| Identify and read NFC | The explicit reader checks the exact target, Gen1 model, current patch information, and all three FRAM CRCs before returning a closed lifecycle result. The independent `Libre2Gen1ReadTransaction` core is tested but remains unwired to a production reader. |
| Activate | One debug/host-authorized transaction verifies the pre-state and post-state and preserves a durable outcome journal. One bench activation reached `warmingUp`. This is not an automatic step for an active sensor, and an unknown outcome cannot be replayed. |
| Enable streaming | One journaled NFC operation persists its chosen base before transmission and confirms the response-derived receiver only after close, audit, and lease release. It is not repeated for saved-receiver reconnects. |
| Disconnect locally | The Libre session cancels its local subscriptions and disconnects BLE. It does not remove an Android bond, change the sensor receiver, clear calibration, or reset a sensor. Cleanup uncertainty retains the driver lease; explicit caller-visible failure propagation is a separate review gate. |
| Reconnect to the same receiver | An explicit connection rereads protected bootstrap state, waits for a fresh exact-target advertisement, reserves a new durable login count, writes F001 once, then subscribes to F002 after acknowledgement. One bounded recovery and one quit/reinstall/run restore have bench evidence. They do not prove continuous background operation. |
| Unbind or move to another phone | Not implemented for Libre. The session has no `CgmBondTransferSession` or unsafe-admin implementation. The existing AiDEX Bond Management Service procedure must not be reused for Libre. The pinned reference's Bluetooth-disable comment is not a reviewed transfer protocol or recovery contract. |
| Reset, stop, or extend a sensor | Not implemented. A generic reference UI task name or command comment is not evidence that a Gen1 operation is safe, reversible, or supported. Do not replay activation or delete receiver state to simulate reset. |
| Replace an expired sensor with a new sensor | Not implemented end to end. `LibreGen1StreamingJournal.prepare` refuses any existing record, and the store has one receiver file. A reviewed archive/replacement state must retain old receiver identity and consumed counters; deletion or counter rollback is not a replacement design. |
| Factory conversion | The separate GPL decoder uses same-sensor CRC-verified FRAM, the current FRAM patch seed, factory coefficients, and temperature correction. The frozen Bluetooth patch is kept separate. Accepted output is provisional bench data, not validated body glucose. |
| Manual calibration | Not implemented for Libre: calibration capability is false, fetching returns no entries, and submission rejects the operation. No audited Libre command writes a finger-stick correction to the sensor. A possible future local correction needs its own validated model and provenance; it must not overwrite factory evidence. |
| History | The new driver slice retains only accepted current samples received in that session, with original UTC receipt times and provisional flags. Sensor-minute deduplication spans the single recovery, retention is bounded, and gaps are not filled. It does not request or publish the packet's sparse historical samples, and it is not backfill or durable history. App persistence/export controls remain separate. |
| Process restart | The protected receiver and calibration survived one full Flutter quit/reinstall/run with retained app data. The new process connected and displayed a bench estimate without NFC. Reboot, Keystore loss, process death during an unknown write, and signed-app migration remain unverified. |
| Android release / iOS | Normal Android builds do not register Libre or the NFC capture bridge. Bootstrap and counter access are still coupled to recorder health. iOS has no Libre/CoreNFC bridge, and the current receiver ID contract expects an Android MAC address. Neither a release flag nor an iOS NFC entitlement alone closes these gaps. |

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

1. Complete review of the cache, received-history, UI, and provisional-data
   policy changes. Verify caller-visible uncertain-disconnect behavior. Keep
   private estimates outside normal persistent history and health exports
   unless a separately reviewed policy explicitly permits them.
2. Implement the [recorder-free Android integration slices](libre2-production-integration.md).
   Preserve state-changing journals and exact RF ownership; do not replace
   trace reservations with an unconditional success stub. Harden the receiver
   store to the calibration store's positive-absence, `O_NOFOLLOW`, descriptor,
   owner, permission, and size checks before promoting it to production.
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
- Permit at most one recovery after an acknowledged, subscribed connection
  delivered a CRC-valid packet and then physically disconnected. Require
  confirmed cleanup, the same reread bootstrap, a new fresh advertisement, and
  a fresh durable login count. Errors and repeated valid packets do not renew
  the recovery budget.
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
| Production NFC | A pure read-only Gen1 transaction and synthetic tests are complete but unwired. Current NFC, protected receiver provider, and live driver registration still require the private Android recorder. Follow the [production integration map](libre2-production-integration.md); do not enable recorder/debug flags in a release. iOS NFC support is absent. |
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

The driver currently publishes only the latest provisional sample; history
remains empty. The sample has a receipt timestamp, but the dashboard substitutes
the bench warning for its normal timestamp detail. Decoded age and lifetime are
validated but not projected into session-life fields. These are remaining
integration gaps, not evidence that packets were lost. Before adding history,
define and test the provisional-data persistence/export policy explicitly.

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
