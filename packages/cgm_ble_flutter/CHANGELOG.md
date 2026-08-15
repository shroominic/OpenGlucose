## Unreleased

- Stop active FlutterBluePlus scans before every connection attempt and avoid
  the unused Service Changed subscription during discovery, improving setup on
  Android Bluetooth stacks that cannot connect reliably while scanning.
- Translate `flutter_blue_plus`, platform-channel, adapter-state, and timeout
  failures into privacy-safe `BleFailure` values without retaining native
  descriptions or device identifiers.

## 1.1.0

- Add a fail-closed helper for setting `flutter_blue_plus` Dart/native logging
  to `none` before release BLE operations.

## 1.0.0

- Initial version.
