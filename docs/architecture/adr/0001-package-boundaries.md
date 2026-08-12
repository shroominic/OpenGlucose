# ADR 0001: Separate domain, transport, protocol, adapter, and app

- Status: Accepted
- Date: 2026-08-12
- Owners: `@shroominic`

## Context

OpenGlucose must interpret sensor protocols, access native Bluetooth APIs, and
present normalized glucose state. Putting these concerns in one Flutter app
would make protocol behavior depend on device plugins, make deterministic tests
difficult, and encourage vendor-specific concepts to leak throughout the UI.

There is no practical pure Dart implementation of iOS and Android BLE access;
an operating-system plugin boundary is necessary. That constraint does not
require protocol parsing or domain contracts to depend on Flutter.

## Decision

Maintain five boundaries:

1. `cgm_core` defines sensor-neutral domain and session contracts.
2. `cgm_ble` defines pure Dart BLE transport contracts.
3. Each vendor protocol uses its own pure Dart driver package; `cgm_aidex` is
   the first implementation.
4. `cgm_ble_flutter` adapts a chosen Flutter BLE plugin to `cgm_ble`.
5. `openhealth` is the composition root and owns platform permission UX,
   persistence, display, and demo behavior.

Dependencies point inward to contracts. Neither core package imports Flutter.
A vendor protocol package does not import a native BLE plugin. Platform adapter
code does not interpret sensor packets. Consumers use capabilities and generic
session interfaces rather than downcasting to a vendor implementation.

## Alternatives considered

- **One Flutter application package:** simplest initially, but couples all
  protocol tests to Flutter/native dependencies and makes reuse harder.
- **Vendor driver directly wrapping `flutter_blue_plus`:** smaller package
  count, but mixes transport lifecycle with protocol behavior and blocks pure
  Dart testing.
- **One package containing every vendor:** centralizes discovery but creates a
  growing conditional surface and shared release cadence for unrelated drivers.
- **A different BLE plugin:** possible behind `cgm_ble`; the boundary is more
  important than the current adapter choice.

## Consequences

- Protocol tests can use deterministic in-memory BLE fakes.
- A transport adapter or vendor driver can change independently when contracts
  remain compatible.
- Public contracts require deliberate compatibility and changelog management.
- More packages add bootstrap, CI, dependency, and ownership work; root checks
  must enumerate the entire workspace.
- Cross-package integration and physical-device tests remain necessary because
  unit isolation cannot prove native BLE behavior.

## Follow-up controls

- Enforce dependency direction through analyzer/import checks where practical.
- Test every package in the root command contract and CI.
- Document public API evolution in `docs/compatibility.md`.
- Require an ADR before adding a new cross-cutting framework or reversing a
  boundary.
