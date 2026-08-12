# cgm_ble

Pure Dart Bluetooth Low Energy transport contracts used by OpenGlucose CGM
drivers. The package models scanning, connections, services,
characteristics, bonding, and notifications without selecting a native plugin.

## Why this boundary exists

Sensor protocols should be deterministic and testable without a phone or BLE
stack. A protocol driver depends on `BleTransport`; a platform adapter implements
it. This keeps vendor parsing and session orchestration out of Flutter plugin
code.

Only declarations exported from `lib/cgm_ble.dart` are public. Files under
`lib/src/` are implementation details.

## Workspace use

```yaml
dependencies:
  cgm_ble:
    path: ../packages/cgm_ble
```

```dart
import 'package:cgm_ble/cgm_ble.dart';

Future<List<BleScanResult>> nearby(BleTransport transport) {
  return transport
      .scan(timeout: const Duration(seconds: 10), allowDuplicates: false)
      .toList();
}
```

Production callers normally use a vendor driver rather than calling the
transport directly. Tests should implement in-memory fakes at this interface;
the Flutter adapter lives in `cgm_ble_flutter`.

## Implementation requirements

An adapter must preserve connection and notification errors, honor timeouts,
release scans/subscriptions on cancellation, normalize UUIDs consistently, and
avoid logging payloads or device identifiers by default. Platform permission
prompts belong to the application layer.

## Development

From the repository root, run `make check`. To exercise this package alone:

```sh
cd packages/cgm_ble
dart pub get
dart analyze
dart test
```

Interface changes follow [`docs/compatibility.md`](../../docs/compatibility.md)
and must include contract tests and a package changelog entry.
