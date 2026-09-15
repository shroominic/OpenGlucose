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
    ├── cgm_libre2 (explicit Gen1 debug receiver, target-unverified)
    │       ├── cgm_core
    │       └── cgm_ble
    ├── cgm_yuwell_anytime (debug-gated, target-unverified) ──┐
    │       ├── cgm_core                                     │
    │       └── cgm_ble                                      │
    └── cgm_ble_flutter ─────────────────────────────────────┘
            └── cgm_ble
                    │
                    └── flutter_blue_plus / native BLE APIs
```

Dependencies point toward contracts. `cgm_core` and `cgm_ble` are pure Dart
leaves. `cgm_aidex` composes those contracts without importing Flutter.
`cgm_libre2` uses the domain and BLE contracts for an explicit Gen1 receiver;
its classification and cryptographic primitives remain pure Dart.
`cgm_yuwell_anytime` depends on the domain and
BLE contracts for an explicit private-debug validation path. Its normal policy
publishes no glucose; the gated Android validation build can project only the
exact V1150 packed field as provisional engineering data. It is absent from
the normal driver registry. `cgm_ble_flutter`
implements the transport boundary. The app is the composition root and owns
platform-specific user experience.

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

### `packages/cgm_libre2`

Owns Libre 2-family reference classification, sequence validation, Gen1
cryptographic primitives, and opaque fragment assembly. Its explicit Gen1
driver connects only to the target from a completed native NFC streaming
bootstrap. It reserves a durable login counter before one write-with-response
login and subscribes only after acknowledgement. The Android app owns the
encrypted receiver journal and the separately initiated NFC state changes.
The driver reports CRC-validated packet status; it does not interpret raw
measurements as glucose. Gen2 and Libre 3 live operation remain unimplemented.

### `packages/cgm_yuwell_anytime`

Owns target-unverified CT5 name/UUID classification, checksum and framing
helpers, reversible byte transforms, synthetic authentication arithmetic,
strict record parsers, and a safety-gated BLE session state machine. The live
path requires explicit activation authorization and Android Keystore-backed
credentials plus a durable write journal. It cannot unbind, reset, update,
calibrate, or load vendor code. Its default output policy publishes no glucose.
Only the explicit private Android debug-capture composition can opt in to a
fail-closed, provisional V1150 engineering projection until physical 5P
evidence passes the documented production-promotion gates.

### `packages/cgm_ble_flutter`

Translates the `cgm_ble` contracts to `flutter_blue_plus`. It owns adapter and
native-BLE lifecycle behavior, not sensor semantics. Its tests cannot replace
physical-device verification on every affected platform.

### `openhealth`

Composes drivers through one physical-scan registry, stores presentation
preferences/history, owns runtime permissions, communicates connection and
freshness state, and renders the UI. On IO platforms the registry currently
contains the verified AiDEX driver and Flutter transport. On web and in widget
tests the app uses a deterministic demo driver. Libre 2 is registered only
with `OG_PROTOCOL_CAPTURE_LIVE_LIBRE=true` in an Android debug trace build
using the Libre capture profile. Normal builds do not register it. Yuwell can
be registered only by the explicit Android debug trace
flags; normal debug and release builds do not include it in the driver registry.

## Runtime flow

1. The app asks its `CgmDriver` registry to scan once for all registered
   service UUIDs.
2. Pure vendor matchers map advertisements into sensor-neutral `DiscoveredSensor`
   values with explicit capabilities.
3. The registry stops scanning, routes connection by stable `driverId`, and the
   app observes `CgmSessionSnapshot` values.
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

For the implemented extension points, use the
[sensor driver guide](../development/sensor-driver-guide.md). Drivers declare
`CgmSensorDataProfile` through an optional provider; the app registry separately
declares `SensorConnectionPolicy`. Shared history/restore/archive behavior uses
these declarations rather than treating every sensor as AiDEX. Custom NFC
state machines remain specialized; a connection policy does not authorize
their commands. [ADR 0005](adr/0005-sensor-data-and-setup-policies.md) records
the compatibility boundary. For protocol investigation and bug reproduction,
use the [capture-to-regression workflow](../development/sensor-protocol-workflow.md).
