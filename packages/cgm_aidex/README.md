# cgm_aidex

Pure Dart AiDEX/LinX CGM protocol and driver implementation for OpenGlucose. It
uses the platform-neutral `cgm_ble` transport and publishes sensor-neutral
state through `cgm_core`.

> [!CAUTION]
> This reverse-engineered, early-stage interoperability code is for wellness
> and reference use. It is not endorsed by a sensor vendor and must not be used
> for diagnosis, dosing, treatment, or emergency monitoring.

## Capabilities

- sensor discovery from names, service UUIDs, and manufacturer data;
- encrypted vendor handshake and characteristic orchestration;
- standard and vendor glucose measurements;
- history and optional raw-history synchronization;
- calibration and diagnostic access; and
- explicitly isolated unsafe administration operations.

Unsafe administration can reset, unpair, clear, or modify a sensor. Never make
those operations implicit, automatic, or reachable without a specific warning
and confirmation in the consuming application.

## Workspace use

```yaml
dependencies:
  cgm_aidex:
    path: ../packages/cgm_aidex
```

```dart
import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

Future<DiscoveredSensor> discoverFirstSensor(BleTransport transport) async {
  final driver = AidexSensorDriver(transport);
  return driver
      .scan(timeout: const Duration(seconds: 15), allowDuplicates: false)
      .first;
}
```

Consumers should use the generic `CgmSession` interface and capability flags.
Connection code must subscribe before inspecting `currentSnapshot`, bound its
wait for a ready/error/disconnected state, and disconnect in `finally`. Pass
structured fields through an app-owned, privacy-reviewed presenter; never print
unclassified status text, device names, or identifiers.
Protocol-specific parsing helpers are public only when exported from
`lib/cgm_aidex.dart`; other `lib/src/` details may change.

## Development

From the repository root, run `make check`. To exercise this package alone:

```sh
cd packages/cgm_aidex
dart pub get
dart analyze
dart test
```

Protocol changes require captured behavior to be represented as redacted test
fixtures or constructed bytes, deterministic handshake/session tests, failure
and disconnect coverage, and a package changelog entry. Never commit a sensor
serial, device identifier, personal glucose history, vendor binary, key, or
credential. See [`CONTRIBUTING.md`](../../CONTRIBUTING.md).
