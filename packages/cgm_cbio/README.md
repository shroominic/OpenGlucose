# cgm_cbio

## Resume integration contract

The current live driver owns checkpoint/archive state privately through
`CbioPrivateStateStore`; it does not publish checkpoint proof or raw records to
the host. The metadata integration described below is the historical contract,
superseded by private ownership (see the changelog and
[durable history contract](../../docs/testing/cbio-gs1-durable-history.md)).

`cbioCheckpointMetadataKey` (`cgm.cbio.checkpoint`) is a versioned JSON value
published in session metadata after a contiguous archive prefix is received.
It binds one index/counter witness and optional clock anchor to the sensor's
`storageKey`. It is restricted health/device state, not diagnostic log data.
The host must atomically persist this value with its associated archive in the
existing backup-excluded local store, then restore it into
`DiscoveredSensor.metadata` before reconnecting. The package does not implement
durable storage. Saving metadata independently of its archive is insufficient.

On reconnect the session re-reads the witness index before accepting any
suffix. A different counter, missing witness, malformed JSON, unsupported
version, foreign sensor binding, or invalid anchor provenance fails closed
and disables automatic reconnect. The last good checkpoint and old records
remain intact. Recovery must preserve the old archive; never silently delete
the checkpoint, reset/activate the sensor, or merge another counter era.
Records below a restored witness are also refused: a suffix-only restore has
no evidence to classify those positions as earlier backfill versus a reset.
`cbioResumeStatusMetadataKey` reports `fresh`, `pending`, `confirmed`, or
`failed`. Only `confirmed` includes `cbioConfirmedCheckpointMetadataKey`, the
exact input checkpoint whose witness the driver observed. Hosts must match
that proof to the restored archive before merging its records with a suffix;
a checkpoint string or matching index alone is not reconciliation evidence.
Valid disconnect preserves the proof. Pending and terminal-failed snapshots
never carry it, and caller-provided proof metadata is never trusted.
Legacy `resumeOffset` alone no longer authorizes skipping history. A host with
legacy archived data and no checkpoint must keep that archive separate until
its era has been reconciled; blindly merging the fresh full read is unsafe.

An accepted anchor keeps its original clock provenance and timestamps across
restart. It is not moved to the new host time. Unreconciled restored anchor
metadata is not exposed. `cbioLifecycleMetadataKey` is `unknown`: activation,
warmup completion, session start, and wear lifetime are not sensor-verified.
The non-null legacy `CgmSessionInfo` duration fields do not establish those
facts and must not be presented as a verified lifecycle.

## Optional one-capsule acquisition recovery

Hosts may implement `CbioRecoveryStore`, an additive capability extending
`CbioFullRecordStore` with atomic `readRecovery` and `writeRecovery`. Legacy-only
and full-only stores keep their existing terminal failure behavior. The app
adapter opts in through its restricted history store.

Only the exact `witness-time-mismatch` failure can request recovery. The original
session remains terminal and observable. Notification/state cancellation and
GATT disconnect must all complete successfully, then private writes drain and
one fresh pending capsule commits before a separate authenticated connection
requests raw index1. Existing host subscriptions and methods forward to that
new session. Closing during transition prevents a new connection; a pending
capsule already committed remains authoritative on restart. Cleanup or storage
failure preserves the original terminal reason and forbids a successor link.

The recovery capsule references exact original UTF8 bytes by SHA256, leaves
legacy/fullRecords keys immutable, and holds only the fresh capture. No prior
rows, checkpoint or clock anchor enter it. Presence consumes the single recovery
budget, even when pending; malformed state or a subsequent mismatch fails
closed without another capsule. Bounds are 65535 fresh rows, 4194304 bytes for
fresh state, a 4096-byte fresh header, 4096 bytes of recovery metadata and
4198400 bytes for the complete capsule. There is no truncation or rotation.

Older builds do not understand the selected recovery route. Downgrade is
unsupported; preserve the complete restricted store and roll forward. A fresh
capture is not evidence of a new sensor era or calibrated glucose. Every new
session still uses the existing clock write and exact resume witness guard;
reconnect can fail again, with the recovery budget already consumed. Public
latest/history/rawHistory stay empty and the shared UI remains unchanged.

## Driver boundary

Live driver for the SIBIONICS / Cbio GS1 sensor, plus offline frame inspection.

`CbioSensorDriver` implements `CgmDriver` under driver ID `cbio` and is
registered in the app's platform registry next to the AiDEX driver.
`CbioDiscovery` maps advertisements with service `FF30` to an unverified Cbio /
SiSensing candidate. The UUID is shared by the GS1 and GS3 applications; it
does not identify the exact sensor model. `CbioUuids` also records the `FF31`
receive, `FF32` command, and `2A25` serial characteristics. Name-only matches,
characteristic-only matches, and empty device IDs are rejected.

`CbioGlucoseSession` opens the authenticated vendor link: connect, subscribe to
`FF31`, authenticate, set the sensor clock once, then read. It is fail-closed
and write-minimal. `CbioGlucoseSession.allowedCommandKeys` is the complete list
of frames the session may ever put on the radio (`03 F0` device information,
`19 01` authentication, `06 03` clock, `06 0A` packed read, `06 08` raw read);
anything else is rejected before the transport sees it. Activation (`07`),
reset, thresholds, calibration, key registration, and firmware frames are never
built. The vendor material the link authenticates with is resolved once per
session from an injected `CbioCredentialSource`; it is never logged, published
in a snapshot, or attached to an exception, and the app's platform registry
leaves the driver out entirely when a build did not supply it.

The sensor answers one `06 08` request with a stream of `08` batches pushed to
the same characteristic, so history is an ingest problem rather than a
request/response pair. The session ingests that stream under a bounded window,
publishes `CgmHistorySyncState` progress, replays the witness from the app's
persisted checkpoint before accepting a resumed suffix, and then polls with a
one-minute cooldown after each bounded operation at the first unseen index.
Manual requests share that pacing and overlapping requests coalesce. Production
sessions have no cumulative lifetime read cap; an explicit nullable
`maxReadsPerSession` remains available for capped bench runs. A legacy
`resumeOffset` alone does not authorize skipping records. Raw payloads and their
historical `/10` representation remain private algorithm inputs, not verified
glucose. The public session emits no latest reading and empty `history` and
`rawHistory`. GS1 uses the unchanged shared AiDEX/Libre2 presentation, including
its empty, error and unknown-lifecycle states; it has no raw-value dashboard.

See the [live record](../../docs/testing/cbio-gs1-glucose-live.md) and the
[app integration record](../../docs/testing/cbio-gs1-app-live.md).

For a private diagnostic build, `--dart-define=CBIO_FAILURE_TRACE=true` emits
the existing `CBIO failure=<closed-code>` line at the first terminal driver
failure, including the closed counter-failure category when applicable. It
also emits exactly these allowed lifecycle milestone tokens:

```text
CBIO milestone=cbio.connect.started
CBIO milestone=cbio.ff31.subscribed
CBIO milestone=cbio.auth.ok
CBIO milestone=cbio.clock.set
CBIO milestone=cbio.write.raw-history
CBIO milestone=cbio.disconnected
```

`connect.started` marks an attempt, not an established link. Subscription,
authentication and clock milestones reflect their existing completion events;
`write.raw-history` marks write completion while the session remains active,
not returned records or a confirmed witness. `disconnected` marks the driver's
accepted transport drop, including notification-stream errors; it does not
identify native status8 or its cause. Repeated drop callbacks emit only once,
and forwarding successor logs does not duplicate their milestone output.

The flag defaults to false in every build mode. Output has no raw records,
sensor identifiers, credentials, timing payloads or arbitrary exception/log
text. A throwing trace sink cannot interrupt acquisition or cleanup. Omit the
flag to disable all trace output. UI, BLE setup, polling and failure/recovery
guards are unchanged. This trace does not establish glucose decoding or explain
failures from earlier launches.

Verify the trace in both configurations from this package:

```sh
dart test test/cbio_glucose_session_test.dart
dart run -DCBIO_FAILURE_TRACE=true test/cbio_glucose_session_test.dart
```

Dependencies are only the existing `cgm_core` and `cgm_ble` contracts. There
is no Flutter, native binary, FFI, network, storage, or cryptography dependency.
The implementation contains no vendor-derived algorithm or source.

`parseCbioPlaintextFrame` inspects a complete, already-decrypted V120 frame.
It separates five-byte acknowledgements from packed `0A` record batches and
checks byte range, exact length/count, checksum, and counter bounds. It retains
raw ACK status and raw packed record fields; it does not infer success, units,
epoch, or a `CgmReading`. It contains no key, decryption, fragment assembly,
command writer, automatic retry, or sensor identifier. Only synthetic fixtures
are used in tests. Vendor format observations are recorded in the evidence doc.

Separate offline entry points inspect `08` raw-data batches,
`F0/04` storage replies, and `F0/03` time replies:
`parseCbioRawDataFrame`, `parseCbioStorageFrame`, and `parseCbioTimeFrame`.
These require complete plaintext data frames and reject control ACKs. Raw
records retain `rawTemperature`, `rawDump`, the reading-bearing `rawPayload`
word, and the firmware's `processed` word; `parseCbioRawDataFrame` is the single
owner of that eight-byte layout, so no other path duplicates the offsets. Only
`rawPayload` is converted, at `raw / 10`, and nothing is presented as a
physical unit (`isUnitVerified` is always false). Time fields have no assigned
epoch, and storage status is not interpreted. The existing `CbioFrame`
hierarchy and generic parser acceptance remain unchanged. These entry points do
not select firmware, send queries, or authorize a live read.

`parseCbioActivationFrame` separately reads the five-byte `F0/02` state reply
and preserves its raw byte without an active/inactive enum.
`parseCbioStartAckFrame` checks an explicitly expected `07` activation or `03`
clock-update ACK and retains unknown result/status values. These inspect bytes
only; these parsers do not authorize writes. The separate live session has a
clock builder/write path, but no activation builder or activation write path.

`buildCbioGlucoseQuery` and `buildCbioInformationQuery` reproduce the vendor's
recovered V120 read frames (`06 0A LE16(index) 00 00 C` and `03 F0 selector C`).
`parseCbioGlucoseBatch` decodes only the plaintext `0A` batch layout and refuses
the `08` raw-data layout. `cbio_vendor_frames.dart` builds the masked link
frames the sensor actually accepts, and `cbio_history_archive.dart` assembles the `08`
record stream into an ordered archive with gap and overlap detection.
`CbioGlucoseSyncSession` adds bounded live polling at the newest index and
bounded history paging from the oldest record, with explicit `noRecords`,
`decodeFailed`, `queryFailed`, `budgetReached`, and `historyNotFullyAvailable`
states. `CbioGlucoseRecord.isUnitVerified` is always false: the `08` field has
no established unit or scale. On the live sensor an authenticated session
streams a contiguous raw archive up to the present; the `0A` packed field is
zero throughout, so only `08` carries usable content. See the
[live record](../../docs/testing/cbio-gs1-glucose-live.md).

`inspectCbioReply` reports what a raw `FF31` notification proves under the
plaintext contract: declared length, additive checksum, acknowledgement marker,
mapped opcode, whether any rotation or reversal fits, and whether one constant
byte mask would expose a frame. It returns `unresolved` with a null frame for
the live five-byte payload `23 F7 6F D9 F4`, which no plaintext reading fits.
The inspection does not decrypt, reassemble, or hold a key; a keyed stream
cipher stays untestable here. See the
[reply framing record](../../docs/testing/cbio-gs1-reply-decode.md).

## Vendor material: source exclusion versus artifact embedding

The vendor link needs three values that this package does **not** carry: the
16-byte RC4 stream key, the 16-byte link credential inside the authentication
frame, and the five-byte authentication prompt. They come from the vendor
artifact described in the evidence record, and storing them in this public
repository is not acceptable.

`cbio_credentials.dart` defines the boundary. `CbioCredentials` validates and
holds the three values and never renders them in `toString`; a
`CbioCredentialSource` supplies them and fails closed with
`CbioCredentialUnavailable` when they are absent or malformed.
`CbioMapCredentialSource` reads them from a supplied string map (a process
environment) and `CbioDefineCredentialSource` from `--dart-define` values.
There is no committed real-material default. The map/static sources can be
supplied by their caller, but the app's current define source uses compile-time
constants: material provided through `--dart-define` is embedded in the built
artifact. This is not runtime-only secret provisioning. Excluding private
values from Git does not establish distribution rights or make configured
APKs safe to redistribute; artifact and provisioning policy remain release
gates. See [dependency policy](../../docs/dependencies.md).

`cbioRc4Keystream`, `maskCbioFrame`, `unmaskCbioFrame`, and every builder in
`cbio_vendor_frames.dart` take the key and material as required arguments, so a
caller that has not resolved material cannot compile a call. Run a build or a
bench that needs the live link with a git-ignored define file:

```sh
flutter run --dart-define-from-file=cbio_vendor.local.json
```

where the file supplies `CBIO_VENDOR_STREAM_KEY_HEX`,
`CBIO_VENDOR_AUTH_MATERIAL_HEX`, and `CBIO_VENDOR_AUTH_TRIGGER_HEX`. Tests and
fixtures use synthetic material of the same shape; the real values are never
checked in.

`cbio_decode_comparison.dart` decodes one captured window through both the app's
live path and the evidence path and reports per-record agreement (`compared`,
`agreeing`, `missing`, `disagreeing`). It exists because a field-identity bug is
invisible in an aggregate range and obvious in the bytes: the evidence path once
read the empty `processed` word instead of the reading-bearing `rawPayload` word.

Run package checks from this directory with the pinned Dart SDK:

```sh
dart pub get --offline
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos
dart test
```

Root workspace checks also enumerate this package. Test inputs are synthetic.
The evidence record covers the separately authorized Mac bench probe. A live
protocol and glucose compatibility remain unverified. OpenGlucose is
wellness/reference software, not a diagnosis or treatment system.
