# cgm_core

Sensor-neutral Dart models and session contracts for continuous glucose monitor
drivers. This package has no Flutter or vendor-protocol dependency.

> This is an early-stage software interface for wellness and reference use. It
> is not a medical device API and must not be used to make dosing, diagnosis,
> treatment, or emergency decisions.

## API surface

- normalized glucose readings, trends, session information, calibrations, and
  diagnostics;
- sensor discovery metadata and capability negotiation;
- immutable session snapshots and structured log entries;
- `CgmDriver` and `CgmSession` contracts for vendor implementations; and
- an explicitly separated `CgmUnsafeAdmin` interface for destructive sensor
  operations.

Only declarations exported from `lib/cgm_core.dart` are public. Files below
`lib/src/` are implementation details.

## Workspace use

```yaml
dependencies:
  cgm_core:
    path: ../packages/cgm_core
```

```dart
import 'package:cgm_core/cgm_core.dart';

final reading = CgmReading(
  valueMgdl: 105,
  source: CgmRecordSource.vendor,
  recordedAt: DateTime.now().toUtc(),
);

final displayedMmol = GlucoseUnit.mmolL.convertFromMgdl(reading.valueMgdl);
```

Driver packages implement `CgmDriver` and publish state through
`CgmSession.snapshots`. Consumers should branch on advertised capabilities
instead of downcasting to a vendor session.

## Development

From the repository root, run `make check`. To exercise this package alone:

```sh
cd packages/cgm_core
dart pub get
dart analyze
dart test
```

Public API changes require tests, an entry in this package's `CHANGELOG.md`, and
the compatibility process in [`docs/compatibility.md`](../../docs/compatibility.md).
See [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for review expectations.
