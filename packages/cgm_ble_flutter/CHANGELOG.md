## Unreleased

- Give notification subscriptions a timeout owned by FlutterBluePlus, so a
  failed CCCD write releases the plugin operation mutex before setup recovery.
- Observe Android bond transitions before starting `createBond`, so an
  immediate bonding rejection is not lost when the GATT link disconnects.
- Add Windows bond creation, state verification, and explicit removal through
  the federated WinRT platform interface. Normal disconnect behavior is
  unchanged and does not remove bonds.
- Give service discovery a dedicated 30-second timeout owned by
  FlutterBluePlus. This prevents an earlier Dart timeout from returning while
  the plugin still holds its BLE operation mutex.
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
