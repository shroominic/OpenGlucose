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

## Normalized data profiles

Drivers can also implement the optional `CgmSensorDataProfileProvider` and
return a constant `sensorDataProfile`. This declares model timing defaults,
timestamp meaning, duplicate handling, current-reading eligibility, and whether
retained readings can establish lifecycle timing. Resolving a profile must not
connect, read storage, reserve a counter, or authorize activation.

```dart
const receivedSamples = CgmSensorDataProfile(
  warmupMinutes: 60,
  expectedLifetimeMinutes: 14 * 24 * 60,
  timestampBasis: CgmReadingTimestampBasis.receivedAt,
  duplicatePolicy: CgmHistoryDuplicatePolicy.keepFirst,
  currentReadingPolicy: CgmCurrentReadingPolicy.liveOnly,
  retainedLifecyclePolicy: CgmRetainedLifecyclePolicy.reportedOnly,
);
```

Profiles describe interpretation, not measurement validity or live lifecycle
evidence. Session-reported timing remains authoritative. Use
`canInferRetainedLifecycle` rather than subtracting a minute counter from a
receipt timestamp. Consumers resolve profiles through their driver registry,
including when displaying old archives; they must not identify vendors by
matching profile values. `CgmSensorDataProfile.legacy` preserves the old defaults
for drivers that have not adopted the optional interface.

Use `acquisitionRelative` when live samples retain receipt time but historical
samples use that receipt minus a verified sensor offset. Like `receivedAt`,
this basis cannot infer activation or expiry. Preserve exact per-reading
acquisition evidence separately; the profile is a policy, not that evidence.

`CgmCapabilities.supportsHistory` still means that a driver supports sensor
backfill through `syncHistory`. A live-only sensor can accumulate local received
history while this flag is false. This API adds no reading JSON fields, backfill
operation, calibration method, or device-state transition.

## Model and version observations

`CgmSessionInfo.sensorVariant` optionally carries a `CgmSensorVariant` from the
driver's identification path. Model, region, security generation, and hardware,
firmware, and software revisions are distinct axes. Null means unknown;
revision strings are opaque, not semantic-version ranges. Source records where
identification came from, not authentication or tested retail compatibility.

The descriptor is for local display and historical metadata. Do not use it to
route a connection, select a decoder/profile, or authorize activation or bond
transfer. It does not change `DiscoveredSensor` or required driver/session APIs.
See the [variant guide](../../docs/development/sensor-variants.md) for the
source-backed matrix and rules for extending a reviewed protocol branch.

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
