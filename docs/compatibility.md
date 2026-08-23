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

- Android API 26 and newer; and
- iOS 14 and newer for the app, with iOS 16.1 and newer required for the Live
  Activity widget extension.

The [Apple Watch Smart Stack presentation](apple-watch.md) requires a paired
iPhone on iOS 18 or newer and Apple Watch on watchOS 11 or newer. It is an
iPhone Live Activity display, not a native Watch app or a direct sensor
transport. Physical paired-device verification remains required before a
release can claim Apple Watch compatibility.

These are build floors, not promises that every device, OS release, Bluetooth
stack, background mode, or sensor firmware has been exercised. Web is a demo
and UI-test surface, not a supported physical-CGM transport.

The repository contains an ad-hoc-signed, non-notarized Apple-silicon `arm64`
macOS reviewer preview with a macOS 11 deployment floor. It is not a
supported product target and is not part of the stable mobile release. Intel
Macs are excluded because a locked native dependency does not currently
produce a verified `x86_64` asset. The Darwin BLE dependency compiles the
required GATT operations, but no physical Mac/AiDEX compatibility evidence is
recorded. The dependency does not expose bond-state or bond-removal operations
on macOS, so the app does not offer sensor transfer there. See the
[macOS preview gates](macos-preview.md).

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

Restricted health-state schema three changes history-blob filenames from a
reversible base64 storage key to `history-<sha256>.blob`. Schema-zero/one
embedded histories and schema-two filenames migrate automatically. The rename
is atomic within the restricted directory; a launch interrupted before the
metadata rewrite resumes from either old or new names. If both names exist with
different contents, startup preserves both and fails closed for manual recovery
instead of guessing which glucose history is authoritative.

The local health SQLite repository schema two adds nullable source-platform and
external-record identity columns plus a local tombstone table. Schema-one rows
remain byte-for-byte JSON-compatible and are not retroactively assigned an
identity. The forward migration is additive and transaction-backed. A
schema-one binary can read the stored sample JSON after the upgrade, but cannot
preserve the identity columns when it writes new imports; do not continue
imports after a downgrade. Roll forward to a schema-two build before importing
again. A schema-one binary can lower SQLite's `user_version` while leaving the
additive schema-two columns in place. Schema two probes the table shape before
each additive migration, so a later schema-two launch restores the version
marker without duplicate-column failure. That recovery preserves existing rows;
it does not make schema-one writes source-aware.

The schema-two binary rejects an attempt to open a higher, unknown SQLite
schema version. It leaves that higher version marker unchanged rather than
silently relabelling an unrecognized schema as version two.

Downgrading to a schema-two app after filename migration is unsupported: the
older app cannot locate schema-three blobs even though their bytes remain on
disk. Roll forward to a schema-three build and preserve the original app
container read-only for recovery; do not manually rename or edit live health
state. See [the recovery runbook](runbooks/data-recovery.md).

## Application releases

The OpenGlucose app remains pre-1.0. User-facing behavior can change between
minor development releases, but data loss, silent semantic changes, reduced
platform support, or removed privacy/safety controls are never treated as
casual changes. Record them prominently with migration or recovery guidance.

Only the latest tagged release and `main` receive best-effort fixes. See
[SECURITY.md](../SECURITY.md) for security support and
[ADR 0003](architecture/adr/0003-platform-release-model.md) for release
traceability.
