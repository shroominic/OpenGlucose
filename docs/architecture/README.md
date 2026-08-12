# OpenGlucose architecture

OpenGlucose is a Flutter application composed from small Dart and Flutter
packages. The architecture keeps normalized glucose concepts independent of a
sensor vendor and isolates native Bluetooth code from protocol logic.

## Component map

```text
openhealth (Flutter app, demo driver, platform lifecycle and presentation)
    ├── cgm_core
    ├── cgm_aidex ───────────────┐
    │       ├── cgm_core         │
    │       └── cgm_ble          │
    └── cgm_ble_flutter ─────────┘
            └── cgm_ble
                    │
                    └── flutter_blue_plus / native BLE APIs
```

Dependencies point toward contracts. `cgm_core` and `cgm_ble` are pure Dart
leaves. `cgm_aidex` composes those contracts without importing Flutter.
`cgm_ble_flutter` implements the transport boundary. The app is the composition
root and owns platform-specific user experience.

## Responsibilities

### `packages/cgm_core`

Owns sensor-neutral public concepts: readings, units, trends, discovered-sensor
metadata, session information, capabilities, diagnostics, structured logs, and
the driver/session interfaces. It must not import a vendor driver, BLE plugin,
UI framework, persistence implementation, or network client.

### `packages/cgm_ble`

Defines scan, connection, bonding, service, characteristic, and notification
contracts. It does not request UI permissions or select a plugin. Protocol
tests can provide in-memory implementations of these interfaces.

### `packages/cgm_aidex`

Owns AiDEX/LinX discovery and protocol behavior: parsing, encrypted handshake,
characteristic orchestration, history sync, calibration, diagnostics, and
explicit unsafe administration. It depends only on the domain and BLE
contracts. New sensor vendors should be separate drivers rather than conditionals
inside this package.

### `packages/cgm_ble_flutter`

Translates the `cgm_ble` contracts to `flutter_blue_plus`. It owns adapter and
native-BLE lifecycle behavior, not sensor semantics. Its tests cannot replace
physical-device verification on every affected platform.

### `openhealth`

Composes drivers, stores presentation preferences/history, owns runtime
permissions, communicates connection and freshness state, and renders the UI.
On IO platforms it constructs the AiDEX driver and Flutter transport. On web
and in widget tests it uses a deterministic demo driver.

## Runtime flow

1. The app asks a `CgmDriver` to scan.
2. The driver maps advertisements into sensor-neutral `DiscoveredSensor`
   values with explicit capabilities.
3. The app connects and observes `CgmSessionSnapshot` values.
4. The protocol driver uses `BleTransport` for I/O and translates bytes into
   normalized readings and status.
5. The app displays current and historical data together with connection,
   sync, age, provisional, and error context.
6. Persistence/export receive normalized data rather than vendor-specific
   packets. Raw diagnostics remain bounded and sensitive by default.

The meaningful critical journey is scan, connect, synchronize history, display
freshness accurately, handle a disconnect or stale reading, reconnect, and
recover persisted state without duplication or time shifts.

## Cross-cutting constraints

- **Safety:** OpenGlucose is wellness/reference software. No component may
  become a diagnosis, dosing, treatment, or emergency decision path.
- **Local first:** core use works without an account or mandatory remote
  service. Health data stays on the device by default; any export or
  integration must be an explicit user action. Complete export and delete-all
  workflows are not current verified capabilities.
- **Time and units:** normalize instants unambiguously, preserve precision, and
  make display units explicit at boundaries. Test timezone and DST behavior.
- **Freshness:** a numeric value is insufficient UI state; surface its age,
  connection/sync status, and provisional quality.
- **Capabilities:** callers branch on declared capabilities instead of vendor
  types or assumptions.
- **Destructive operations:** unsafe administration remains visibly separated,
  explicitly confirmed, audited where appropriate, and never automatic.
- **Failures:** BLE, storage, export, background, and third-party failures must
  not silently appear successful or advance durable progress past failed data.

## Extending the workspace

For a new sensor driver:

1. reuse `cgm_core` domain contracts and `cgm_ble` transport contracts;
2. place vendor protocol logic in a separate pure Dart package;
3. construct it in the app's driver registry/composition layer;
4. add protocol fixtures that contain no real identifiers or health data;
5. document known firmware/hardware compatibility and physical-device evidence;
6. avoid expanding `cgm_core` with vendor-only concepts; and
7. write an ADR if a new cross-cutting dependency or boundary is needed.

Public API evolution follows [compatibility.md](../compatibility.md).
Dependencies follow [dependencies.md](../dependencies.md). Accepted decisions
and their implementation status are indexed in [adr/README.md](adr/README.md).
