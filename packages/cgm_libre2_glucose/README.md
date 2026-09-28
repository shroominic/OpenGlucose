# cgm_libre2_glucose

A separate **GPL-3.0-only**, pure Dart Libre 2 security-Gen1 factory decoder.
It converts CRC-checked encrypted BLE records using coefficients from the
same receiver's CRC-checked encrypted FRAM. It does not scan, connect, activate,
store data, or change the existing MIT protocol package.

This is a reference-derived estimate, not a clinically validated measurement.
Agreement with an open-source formula is not device conformance or evidence
of medical accuracy. An expired sensor placed in fruit can test transport and
arithmetic, but cannot establish valid human glucose readings.

## API and integration contract

```dart
final decoder = Libre2Gen1GlucoseDecoder.fromEncryptedFram(
  uid: protectedBootstrap.uid, // 8 bytes in algorithm order
  initialPatchInfo: matchedCalibration.calibrationPatchInfo, // 6 current NFC bytes
  encryptedFram: matchedCalibration.encryptedFram, // exactly 344 bytes
);
final packet = decoder.decodeEncryptedBle(encryptedF002Composite); // 46 bytes
final current = packet.current;
if (current.glucoseMgDl != null) {
  // Reference-derived estimate only. Apply the app's remaining safety gates.
}
```

The caller must bind all context bytes to the SAME protected receiver bootstrap
and retire the decoder when that bootstrap changes. CRC is not authentication.
Despite its historical parameter name, `initialPatchInfo` here must be the
current NFC patch read with this FRAM, not the frozen receiver patch used for
Bluetooth login. The app retains both values: it verifies the exact bootstrap
ID, UID and original receiver patch, then checks the current patch's supported
model and stable first four bytes before decoding. Bytes four and five can
differ; all three FRAM CRCs must pass with the current patch. This does not
authorize changing the saved Bluetooth credentials or login counter.
Never use a FRAM capture selected only by length, a global last-capture file, or
a different sensor's coefficients. The constructor checks UID shape/manufacturer,
known Libre 2 Gen1 model, every FRAM CRC, lifecycle at capture, table index,
positive calibration scale/reference, and a declared positive sensor lifetime.
Libre 2 Plus, Gen2 and Libre 3 are not supported.

The decoder retains no byte getters, mutable packet history, wall clock, or
I/O. It emits ten immutable sample positions: seven sparse trend readings
(offsets 0/2/4/6/7/12/15 minutes) and three 15-minute history positions.
`sensorAgeMinutes` and `sensorMinute` are counters, not dates. The app must map
them against the BLE observation time, deduplicate, reject older/replayed
packets, manage disconnects, and preserve source attribution.

`lifecycleAtFram` is explicitly historical. Passing minute 60 does not prove
that the sensor is currently active, healthy, or in date. The app must not turn
a historical warming-up snapshot into a current lifecycle assertion. This
package suppresses sample minutes below 60, pre-start samples, packets before
the FRAM capture's sensor age, and records at/after declared maximum life.
The app must also gate known failed/expired/shutdown lifecycle evidence.

Raw-zero records always yield `sensorError`, retaining the full encoded
12-bit quality field and its two flag bits. Unknown quality bits are not
accepted as glucose. Invalid logarithm/division domains, nonfinite values,
nonpositive output, and values beyond signed-32-bit representation yield no
value. These are mathematical checks, not clinically established temperature
or glucose limits. No ADC/10 fallback, invented timestamps, interpolation,
physiological clipping, or reading is substituted on any rejected path.

## Evidence and limits

- GPL factory formula/tables and coefficient offsets:
  [xdripswift pinned source](https://github.com/JohanDegraeve/xdripswift/tree/53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8/xDrip/BluetoothTransmitter/CGM/Libre/Utilities).
- Separately MIT BLE layout and age fields:
  [DiaBLE Libre2.swift](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift),
  [Libre.swift](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre.swift).
- Manufacturer's 60-minute warm-up:
  [Abbott Libre 2 guide](https://provider.freestyle.abbott/content/dam/adc/provider/countries/ca-en/pdfs/ADC-33699_v2_ART-00-of-05-C02204_FSL2-Getting-Started-Guide-Digital_FINAL.pdf).
  Minute 60 is only the minimum gate; it is not proof that all warm-up or error
  conditions have ended.
- Crypto/decryption is delegated to the MIT cgm_libre2 core and its existing
  provenance/CRC tests.

The tests use synthetic bytes and a synthetic UID. No private capture,
manufacturer matched-reading oracle, or clinical dataset is included.
The checked-in Swift source is an independent-language arithmetic oracle,
not an approved Abbott algorithm implementation.

## Verify

```sh
dart pub get --offline
dart analyze
dart test
dart run tool/verify_reference_vectors.dart
```

The last command requires Swift on the host. It runs the pinned original
factory method and original tables against all 1023 coefficient indices and
compares the resulting rounded values with the checked-in synthetic vectors.
Dart tests decrypt synthetic FRAM/BLE, then compare its conversion against those
vectors and check CRC/input/model/lifecycle/age/quality/domain rejection.
Vector columns are index, signed offset, scale, temperature reference, raw
glucose, raw temperature, signed temperature adjustment, rounded reference
mg/dL. They are not real sensor readings.

## Private offline bench analysis

On a Darwin64 Mac, run the following only with explicitly selected private
capture files. The tool requires existing absolute paths, current effective
user ownership, exact mode `0600`, regular files, and no final symlink.
It uses descriptor-bound reads and checks ownership/permissions before and
after reading. Unsupported ABIs fail closed. Calibration is bounded to 16 KiB;
the BLE JSONL is bounded to 32 MiB, 100,000 lines and 64 KiB per line.

```sh
dart run tool/analyze_private_bench.dart \
  --calibration /absolute/private/calibration.json \
  --ble /absolute/private/ble.jsonl
```

The calibration schema must exactly match the host-bound v1 FRAM artifact or
the native explicit-read v2 artifact (including null `captureSessionId`). UID
and patch hashes, manufacturer, type, byte lengths and all FRAM CRCs are checked.
This is historical offline evidence, not live session authorization. The
explicit files are never searched for, modified, copied, or uploaded.

Only one device's FDE3/F002 notifications can be analyzed. Three fragments must
be 20/18/8 bytes with one correlation ID and no more than 10 seconds from first
to last. Stream/connection boundaries never join packets. Duplicate JSON keys,
multiple target devices, nonmonotonic trace ordering and ambiguous fragment
sequences fail closed. A trailing partial packet is counted but not decoded.
The tool emits exactly one JSON line with counts and closed reasons. It never
prints glucose, raw values, IDs, hashes, timestamps, paths, or stack traces.
Counts describe recorded packet observations, not distinct or clinically valid
measurements. UTC ordering does not establish real-world freshness or accuracy.

## Distribution gate

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [LICENSE](LICENSE).
Owner approval to try the GPL route does not by itself make an App Store,
TestFlight or binary distribution compliant. Combined-work obligations, all
dependency licenses, complete corresponding source, notices, installation
requirements where applicable, and platform terms must be reviewed before
release. Existing MIT files retain their notices.
