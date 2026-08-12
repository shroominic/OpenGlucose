# Compatibility and deprecation policy

This policy distinguishes the reusable Dart/Flutter package contracts from the
pre-1.0 OpenGlucose application. A passing build is not proof of compatibility
with a sensor or operating-system behavior.

## Supported toolchain and platforms

The baseline development toolchain is Flutter 3.41.6, Dart 3.11.4, and Java 17.
Manifests currently declare Dart `^3.11.4` and Flutter `>=3.35.0`; CI validates
the pinned baseline and should add an explicit compatibility lane before
claiming support for a wider range.

The current native project configuration targets:

- Android API 24 and newer, inherited from the pinned Flutter toolchain; and
- iOS 13 and newer for the app, with iOS 16.1 and newer required for the Live
  Activity widget extension.

These are build floors, not promises that every device, OS release, Bluetooth
stack, background mode, or sensor firmware has been exercised. Web is a demo
and UI-test surface, not a supported physical-CGM transport. Desktop platforms
are not currently product targets.

Changes to a platform floor require a user-impact assessment, updated manifests
and docs, affected platform builds, and an entry in the root changelog.

## Package contracts

The public API of a package is the surface exported from its top-level library:

- `package:cgm_core/cgm_core.dart`
- `package:cgm_ble/cgm_ble.dart`
- `package:cgm_aidex/cgm_aidex.dart`
- `package:cgm_ble_flutter/cgm_ble_flutter.dart`

Declarations below `lib/src/`, unexported helpers, test fixtures, and diagnostic
text are not public contracts. Observable wire behavior, serialized formats,
storage keys, time/unit semantics, error types, and capability meanings may be
contracts even when they are not Dart declarations.

Packages use Semantic Versioning independently:

- patch: compatible corrections and implementation changes;
- minor: backward-compatible additions; and
- major: breaking API or behavior changes.

Until packages are independently published, path dependencies make integration
atomic in this repository, but callers and future publishing still require the
same compatibility discipline.

## Deprecation and breaking changes

Prefer additive changes and capability negotiation. A deprecation must include
an annotation when Dart supports it, package changelog entry, replacement and
migration example, and a target removal release. Keep a deprecated public API
for at least one minor release and 90 days after a tagged replacement release,
unless retaining it creates a documented security or safety risk.

A breaking change requires:

1. a linked issue or ADR explaining impact and alternatives;
2. contract tests for old and new behavior when coexistence is possible;
3. coordinated version updates for affected packages;
4. package and root changelog entries plus migration guidance; and
5. explicit maintainer approval.

Security and product-safety fixes may remove unsafe behavior faster. Document
the exception, affected versions, mitigation, owner, and reason normal notice
was unsafe.

## Data and protocol compatibility

Persisted data changes require a versioned migration, forward/backward
expectations, representative fixtures, roll-forward/recovery behavior, and
tests for interrupted or repeated migration. Preserve unknown fields or values
when practical so newer data is not destructively downgraded.

Time values must preserve an unambiguous instant and sufficient precision;
display-zone conversion happens at the UI boundary. Unit conversions must be
explicit and tested at rounding and threshold boundaries.

Sensor compatibility claims require a documented model/firmware/platform
combination, redacted physical-device evidence, expected capability gaps, and a
last-verified release/date. A shared name, service UUID, or demo-driver result
alone is not compatibility evidence. Protocol changes should remain tolerant
of unknown data while failing safely on malformed or unauthenticated input.

## Application releases

The OpenGlucose app remains pre-1.0. User-facing behavior can change between
minor development releases, but data loss, silent semantic changes, reduced
platform support, or removed privacy/safety controls are never treated as
casual changes. Record them prominently with migration or recovery guidance.

Only the latest tagged release and `main` receive best-effort fixes. See
[SECURITY.md](../SECURITY.md) for security support and
[ADR 0003](architecture/adr/0003-platform-release-model.md) for release
traceability.
