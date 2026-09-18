# cgm_cbio

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
built. The 16-byte link credential comes from a `CbioAuthMaterialProvider`
whose compiled default is the derivation-recorded constant; it is never logged,
published in a snapshot, or attached to an exception.

The sensor answers one `06 08` request with a stream of `08` batches pushed to
the same characteristic, so history is an ingest problem rather than a
request/response pair. The session ingests that stream under a bounded window,
publishes `CgmHistorySyncState` progress, resumes from the app's persisted
`resumeOffset`, and then polls once a minute at the first unseen index. Every
emitted reading is `CgmRecordSource.raw` with `isDisplayProvisional` set, and
`cbioProvisionalUnitNotice` is the marker the UI shows: the raw field divided
by ten is plausible but no reference measurement has confirmed the scale.

See the [live record](../../docs/testing/cbio-gs1-glucose-live.md) and the
[app integration record](../../docs/testing/cbio-gs1-app-live.md).

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
records retain temperature/current/dump integers plus packed fields; none is
converted to a physical unit. Time fields have no assigned epoch, and storage
status is not interpreted. The existing `CbioFrame` hierarchy and generic
parser acceptance remain unchanged. These entry points do not select firmware,
send queries, or authorize a live read.

`parseCbioActivationFrame` separately reads the five-byte `F0/02` state reply
and preserves its raw byte without an active/inactive enum.
`parseCbioStartAckFrame` checks an explicitly expected `07` activation or `03`
clock-update ACK and retains unknown result/status values. These inspect bytes
only. The package contains no activation/clock builder or live write path.

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

## Vendor material is injected, never compiled

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
There is no compiled default.

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
