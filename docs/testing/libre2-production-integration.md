# Libre 2 Android production integration

Status: recorder-free read-only Android integration implemented, default off;
saved-receiver composition is now available only in explicitly opted-in Android
debug validation. Production sensor connection remains disabled. Updated 2026-09-10.
Scope: the reviewed Libre 2 security-Gen1 branch, not Plus, Gen2, or Libre 3.

## Read-only core and Android integration

[Libre2Gen1ReadTransaction](../../openhealth/android/app/src/main/java/com/aidex/aidex_flutter/Libre2Gen1ReadTransaction.java)
is a pure, injected read-only core. It sends one patch-information read and
the fifteen fixed FRAM reads, verifies all three CRCs, and returns a closed
lifecycle plus restricted native evidence only after transport close succeeds.
It does not activate, enable streaming, publish glucose, register NFC, or access
files. Each instance is single-use, including after failure. Response buffers
and partial evidence are cleared. The existing recorder and journals are unchanged.

The [synthetic tests](../../openhealth/android/app/src/test/java/com/aidex/aidex_flutter/Libre2Gen1ReadTransactionTest.java)
cover exact frames, lifecycle states, each CRC region, malformed responses,
unsupported families, target changes, revocation at every guard boundary,
transport/close failures, evidence isolation, and no retry. Run
`./scripts/test-libre-nfc-java.sh`; all eleven suites passed for this extraction.
These tests do not establish physical-device or production support.

The core is now used by `Libre2NfcSessionCoordinator` and `Libre2NfcBridge`.
The explicit Gradle property `openGlucoseLibreNfcReadOnly=true` selects this
reader instead of the debug recorder. Its default is `false`; malformed values
fail the build. The main manifest declares NFC as an optional hardware feature.
The normal AiDEX registry is unchanged. In release/profile this option does not
enable the Libre BLE receiver. Android debug builds can additionally restore
an existing receiver through the separate private-validation composition below.
No decoder, activation, or streaming setup is enabled by this option.

The dedicated method channel is `com.openglucose/libre2`; closed UI events use
`com.openglucose/libre2_events`. `capabilities({})` has exactly seven fields:
`schemaVersion: 1`, `backend: readOnly`, `readAvailable`, and four false flags:
`activationAvailable`, `streamingAvailable`, `receiverAvailable`, `rawCapture`.
The only reader operations are `startLibre2NfcSetup` and exact-attempt
`stopLibre2NfcSetup`.
No raw sensor identifiers, FRAM, coefficients, receiver bytes, or native error
text enter these events. NFC disabled and foreground checks happen again at
start. Android reader mode is [foreground scoped](https://developer.android.com/reference/android/nfc/NfcAdapter#enableReaderMode(android.app.Activity,%20android.nfc.NfcAdapter.ReaderCallback,%20int,%20android.os.Bundle)).

The coordinator bounds one attempt to 120 seconds, serializes read operations,
revokes on pause/exact-attempt stop/detach, and publishes success only after confirmed
transport close, reader shutdown, and exact-owner lease release. Uncertain
cleanup keeps the lease and blocks reuse, including after a late close. The
read evidence is wiped after the closed lifecycle result; this slice creates
no reusable activation/streaming proof.

Before reader admission, the backend syncs the owner file and each containing
directory, then rechecks exact ownership. Cleanup performs all fallible sync
and owner checks before deletion. Successful exact-owner lease-directory
deletion is the release success point; no later fallible sync can turn that
success into an uncertain result with no restart blocker. A crash can restore
a released lease and conservatively block reuse. A pre-delete or partial-delete
failure retains the directory blocker. The app never recreates or resets an
unknown lease. An eight-second watchdog quarantines pending cleanup even if
Dart disappears after native start fails.

Cancelling an event subscription stops event delivery, not RF ownership. Normal
UI teardown sends exact-attempt stop separately. An unexpected lost listener
cannot cancel a newer owner; foreground and attempt deadlines still apply.

`libre2_platform.dart` selects the matching method/event backend without a
fallback to debug capture. Native capability validation enables the existing
inline UI. A cancelled capability lookup cannot dispatch a late native start;
after dispatch, capability loss cannot skip native cleanup. Read-only sessions
cannot poll/accept activation proof or return a completed-read handoff token.
Native pause can invalidate a displayed read without reviving it from its
expired UI timer. The debug setup behavior remains separate.

This first slice intentionally blocks existing receiver/calibration files,
capture/grant/journal contents, and uncertain legacy leases. It neither deletes
nor migrates them. The current private sensor container is therefore not an
eligible test container for this backend. Do not clear that container to make
the check pass. Physical testing requires a separately approved eligible
device/container, with no hidden receiver migration or sensor-changing command.

## Next implementation slices

1. **Validate the read-only integration (R2).** Run the native coordinator,
   Dart routing, UI, and default/opt-in Android builds. Then collect physical
   foreground, tag-loss, pause/cancel, expiry, and close evidence on an eligible
   container. Passing synthetic tests is not physical reader validation.

2. **Complete receiver integration.** Recorder-free native/store/transport
   components now exist with a separate exact-owner channel and durable
   connection lease. See the [receiver contract](libre2-receiver-integration.md).
   The existing recorder-free selector now registers the separate bridge only
   in debuggable applications. Android debug normal-main composition can restore
   an exact saved receiver without capture or enrollment authority. Normal
   release composition, process-death/unknown-owner recovery, initial enrollment,
   and device evidence are still required.
   A separate exact-receiver NFC history purpose now reuses the existing reader
   and importer after BLE cleanup. The existing private glucose entry can inject
   protected calibration without trace flags; normal main stays decoder-free.
   This is not new enrollment or a distribution approval.
   Do not route receiver methods to the read-only channel or bypass a retained
   lease. The installed private driver still uses the recorder path.

3. **Streaming receiver (separate R3 slice).** Add a production streaming
   transaction that accepts only fresh, same-target native read evidence.
   Reuse `LibreGen1Streaming` and `LibreGen1StreamingStore/Journal` unchanged:
   persist the chosen base before contact, recheck patch/CRC/lifecycle, consume
   intent before the single enable command, and parse the exact response.
   Confirm bootstrap only after close, durable completion, and exact lease
   release. Replace raw trace reservations with a reviewed compact encrypted
   operation journal, not a no-op trace sink. Expose existing bootstrap,
   counter-reserve, and outcome-mark contracts behind native ownership guards.

4. **Activation (separate R3 slice).** The existing activation executor remains
   host-grant/capture-file bound. A later production transaction needs explicit
   activation intent, durable pre-send consumption, and CRC-verified post-state.
   Unknown outcomes must block replay. Connection to an already-active sensor
   must not activate it. Preserve the existing verified activation journal.

## Evidence and preservation gates

- Before integration, agree the R2 reader/storage policy and the separate R3
  streaming/activation approval boundaries. Raw capture is not a production
  prerequisite; durable state-changing intent and cleanup proof remain required.
- Reuse the exact-owner RF lease primitive in an app-private location, but do
  not bypass unresolved legacy leases or activation/streaming journals. Define
  explicit recovery before enabling a new backend over existing private state.
  Never delete an unknown journal or automatically move credentials from the
  separate debug application into the signed application.
- Add coordinator tests for pause/back/detach, late callbacks, double taps,
  expired evidence, wrong targets, close failure, and restart with unresolved
  state. Then record redacted physical tag-loss and lifecycle evidence on the
  opt-in Android build. Test known/unknown receiver restore and counter handling.
- Verify the release-like manifest and channels exclude the recorder, raw logs,
  and debug metadata. Run mixed-registry/UI and physical AiDEX/LinX regression
  checks before enabling Libre in the normal registry.
- A production NFC path alone does not supply calibrated glucose. The remaining
  license, decoder, current lifecycle, recovery, device-output, and distribution
  gates are listed in [release readiness](libre2-release-readiness.md).

No iOS implementation or cross-platform support claim is part of these slices.
