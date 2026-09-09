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
