# OpenHealth

Your Open-source health and wellness app focused on local data and privacy.

## Flutter CGM SDK Workspace

This workspace splits the CGM stack into a pure Dart protocol layer and a very
thin Flutter transport layer:

- `packages/cgm_core`
  Sensor-agnostic domain models, session contracts, logs, diagnostics, and
  capabilities.
- `packages/cgm_ble`
  BLE transport abstractions used by CGM drivers.
- `packages/cgm_aidex`
  Pure Dart AiDEX driver and protocol implementation. This package owns the
  encrypted vendor handshake, CGM characteristic orchestration, history sync,
  calibration flow, diagnostics, and unsafe admin commands.
- `packages/cgm_ble_flutter`
  Flutter transport bridge built on `flutter_blue_plus`. It only translates
  scan/connect/read/write/notify operations into the `cgm_ble` interfaces.
- `openhealth`
  Reference UI. On Flutter IO platforms it uses the real AiDEX driver; on web
  and in widget tests it falls back to a demo driver so the UI remains
  verifiable without native BLE.

## Why the BLE split exists

The AiDEX protocol itself is now Dart. The remaining platform boundary is BLE
transport. There is no practical fully pure-Dart way to talk to Bluetooth LE on
iOS and Android without crossing into the operating system's native BLE APIs.

The chosen compromise is:

- keep all protocol logic in Dart
- keep only the BLE transport in a Flutter package
- keep that transport minimal so future CGM drivers can reuse it

## BLE options considered

- `flutter_blue_plus`
  Broad platform coverage, straightforward scan/connect/read/write/notify API,
  explicit Android bonding support.
- `flutter_reactive_ble`
  Good reactive API, but the driver still needs a platform plugin boundary and
  the characteristic orchestration would not get any more "pure Dart".
- `universal_ble`
  Wide platform coverage, but the same underlying constraint remains: BLE still
  depends on platform integrations.

For this workspace, `flutter_blue_plus` is used because it gives the smallest
adapter surface for the needs in `cgm_ble`.
