# cgm_cbio

Pure Dart scaffold for the Cbio GS1 / SiSensing investigation. Version 0.0.1
has pure discovery mapping and offline frame inspection. It cannot scan,
connect, authenticate, activate, publish glucose, or change a sensor.

`CbioSensorDriver` reserves driver ID `cbio` and implements `CgmDriver`.
Both I/O entry points fail with `CbioProtocolUnavailableException`; a scan
failure is not reported as a successful scan with no devices. The constructor
has no transport. All capabilities are false. `CbioDiscovery` maps advertisements
with service `FF30` to an unverified Cbio / SiSensing candidate. The UUID is
shared by the GS1 and GS3 apps; it does not identify the exact sensor model.
`CbioUuids` also records `FF31` receive and `FF32` command characteristics.
Name-only matches, characteristic-only matches, and empty device IDs are rejected.

The package is not registered in the app. The registry requires a nonempty
service list; use `CbioDiscovery.scanServiceUuids` for a future explicit bench
composition. Candidate metadata cannot open a session. See the [registry map and RE evidence](../../docs/testing/cbio-gs1-offline.md)
for the macOS integration point and remaining work.

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
only. The package contains no activation/clock builder or live write path.

`buildCbioGlucoseQuery` and `buildCbioInformationQuery` reproduce the vendor's
recovered V120 read frames (`06 0A LE16(index) 00 00 C` and `03 F0 selector C`).
`parseCbioGlucoseBatch` decodes only the plaintext `0A` batch layout and refuses
the `08` raw-data layout. `cbio_crypto.dart` carries the vendor's static
per-frame stream mask, `cbio_vendor_frames.dart` builds the masked link frames
the sensor actually accepts, and `cbio_history_archive.dart` assembles the `08`
record stream into an ordered archive with gap and overlap detection.
`CbioGlucoseSyncSession` adds bounded live polling at the newest index and
bounded history paging from the oldest record, with explicit `noRecords`,
`decodeFailed`, `queryFailed`, `budgetReached`, and `historyNotFullyAvailable`
states. `CbioGlucoseRecord.isUnitVerified` is always false: the `08` field has
no established unit or scale. On the live sensor an authenticated session
streams a contiguous raw archive up to the present; the `0A` packed field is
zero throughout, so only `08` carries usable content. See the
[live record](../../docs/testing/cbio-gs1-glucose-live.md).

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
