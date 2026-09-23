# Libre 2 Android production integration

Status: extraction started; production NFC remains disabled. Updated 2026-09-05.
Scope: the reviewed Libre 2 security-Gen1 branch, not Plus, Gen2, or Libre 3.

## Completed, not wired

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

## Next implementation slices

1. **Foreground reader and dedicated channel (R2).** Add proposed
   `Libre2NfcBridge.java` and `Libre2NfcSessionCoordinator.java`. Use
   `com.openglucose/libre2` and `com.openglucose/libre2_events`, with strict
   capabilities and the existing closed start/stop/status vocabulary. Update
   `MainActivity.java` lifecycle forwarding and an explicit, default-off native
   build option in `android/app/build.gradle.kts`. Select exactly one backend
   per build: production reader or debug recorder, never two reader-mode owners.
   Add optional NFC permission/feature to the main manifest only with this
   reviewed integration. Do not enable release tracing or weaken recorder gates.

   The coordinator owns one explicit attempt, tag, native/process generation,
   foreground lease, and bounded monotonic deadline. Its Android adapter must
   validate the ISO15693 manufacturer and serialize actual connect/transceive
   calls with the native authorization lock. The core's separate `Guard`
   callbacks are not an atomic RF mutex. Cancellation must close exactly once;
   uncertain close retains the lease and blocks a replacement attempt. Retain
   fresh read evidence only in native memory, with attempt and observation
   clocks; raw evidence must not enter Flutter UI or ordinary logs.

2. **Dart routing, without a new UI.** Add proposed `libre2_platform.dart` to
   select capabilities/methods/events. Inject it into `libre2_nfc_setup.dart`,
   `libre_gen1_streaming_setup.dart`, and `libre_gen1_secure_store.dart`, which
   already have test injection points. Update factories in
   `sensor_connection_screen.dart`; keep the current inline widgets. Availability
   must come from strict native capabilities, not a hard-coded success or
   `kDebugMode`. Keep AiDEX registered. Add Libre to the normal registry only
   when the receiver slice is complete; retain its discovery-restore hook.

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
