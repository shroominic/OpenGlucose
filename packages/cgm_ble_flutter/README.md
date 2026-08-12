# cgm_ble_flutter

Flutter implementation of the `cgm_ble` transport contracts, backed by
`flutter_blue_plus`. It translates platform scan, connect, bond, discovery,
read, write, and notification operations; it does not contain sensor protocol
logic.

## Workspace use

```yaml
dependencies:
  cgm_ble_flutter:
    path: ../packages/cgm_ble_flutter
```

```dart
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';

const transport = FlutterBluePlusTransport(
  adapterReadyTimeout: Duration(seconds: 10),
  operationTimeout: Duration(seconds: 12),
);
```

Pass the transport to a compatible protocol driver, such as
`AidexSensorDriver` from `cgm_aidex`. Applications remain responsible for
platform Bluetooth declarations, runtime permission UX, lifecycle behavior,
and clearly communicating stale or disconnected data.

## Platform behavior

- Android supports explicit bond lifecycle operations through the adapter.
- iOS and macOS configure `flutter_blue_plus` power alerts and optional state
  restoration.
- Web is not the OpenGlucose hardware path; the reference app uses its demo
  driver there.

Consult the `flutter_blue_plus` documentation when changing native permission
or build configuration. Verify adapter changes on the affected physical
platform; unit or web tests cannot establish BLE compatibility.

## Development

From the repository root, run `make check`. To exercise this package alone:

```sh
cd packages/cgm_ble_flutter
flutter pub get
flutter analyze
flutter test
```

Transport changes require deterministic adapter tests where practical, native
smoke evidence, and the compatibility process in
[`docs/compatibility.md`](../../docs/compatibility.md).
