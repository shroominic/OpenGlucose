# cgm_yuwell_anytime

Pure Dart clean-room protocol primitives and a safety-gated BLE session driver
for the Yuwell Anytime CT5 family.

> [!CAUTION]
> These primitives are **reference-verified**, and discovery/GATT
> topology/version handshake are additionally **target-confirmed on one
> physical Anytime 5P** (macOS BLE, 2026-09-09 — see
> [the evidence boundary](doc/evidence-boundary.md)). A matching name, UUID,
> frame, or version handshake does not establish full Anytime 5P hardware
> compatibility or a working glucose value: that unit's firmware branch was
> not `V1150`, so the session stopped at the version check by design.
> OpenGlucose is wellness/reference software. Do not use this package for
> diagnosis, dosing, treatment, or emergency monitoring.

## Implemented boundary

- exact `Anytime` plus ten decimal digits candidate classification, with a
  one-way storage key and generic display name;
- CT5 service, notify, and write UUID constants;
- additive 8-bit checksum creation and strict frame validation;
- pure encoders for version, check-ID, local date, set-ID, sensor-code query,
  configuration, initialization, low-power, history, and live ACK frames;
- a reversible one-byte-key XOR and bit transform;
- strict decoded 11-, 15-, and 17-byte history-record parsing;
- strict passive 3-byte current/temperature and glucose record parsing;
- strict splitting of a caller-provided 12-digit communication identity;
- pure decoding of the three fixed-width CT5 SSN/calibration-code layouts;
- a pure, redacting V1150 packed-versus-native comparison report for private
  differential evidence; and
- target-unverified 5P lifecycle metadata: 45-minute warmup, 16-day wear, and
  3-minute sample interval;
- notify-before-write topology verification, strict response routing, and
  immediate live ACK before parsing;
- injected Keychain/Keystore credential and atomic write-journal contracts;
- explicit one-shot activation authorization, durable pre-write identity and
  initialization state, and read-only interrupted-write recovery; and
- automatic private history synchronization with negotiated-MTU batching when
  the transport can prove the actual MTU.

All returned byte lists are immutable. Parsed records retain their original
bytes and uninterpreted fields so later evidence does not require destructive
re-decoding.

## Deliberate exclusions

The package does not include a plaintext credential store, a platform BLE
adapter, NFC, background service, application UI, proprietary binary, vendor
source, real sensor identity, key, serial, payload, or capture. It never calls
OS bonding APIs and exposes no automatic unbind, reset, OTA, calibration, or
unsafe-admin path.

State-changing activation is disabled unless the caller supplies an explicit
one-shot authorization and durable secure-store implementations. Unknown write
outcomes are journaled and are not blindly retried.
If activation-prepared credentials survive without a matching journal, the
driver fails closed; it does not infer whether initialization reached the
sensor.

Only the exact `V1150` transport branch is admitted. Its packed transmitter
glucose remains target-unverified because the reference connected path also
uses a stateful native algorithm. The default output policy keeps warmup,
history, and live records private in memory. A caller can explicitly inject the
engineering-provisional policy to project only authenticated, contiguous,
post-warmup V1150 packed values as provisional `CgmReading` values. Normal
OpenGlucose builds do not inject that policy. Pre-`V1150` firmware fails closed.

## Offline example

```dart
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';

final candidate = classifyYuwellAnytimeDeviceName('Anytime0123456789');
final request = YuwellCt5Commands.readHistory(
  startIndex: 0,
  recordCount: 1,
);

assert(candidate == YuwellAnytimeNameKind.anytimeFamily);
assert(hasValidSum8Frame(request));
```

Real notifications and sensor identifiers are restricted device data. Do not
print, commit, or place them in test fixtures. See
[the evidence boundary](doc/evidence-boundary.md).

## Development

```sh
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos
dart test
```
