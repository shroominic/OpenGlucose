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
- `package:cgm_cbio/cgm_cbio.dart` (offline, target-unverified scaffold)
- `package:cgm_libre2/cgm_libre2.dart`
- `package:cgm_libre2_glucose/cgm_libre2_glucose.dart` (separate GPL bench decoder)
- `package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart`
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

`cgm_cbio` 0.0.1 is a Cbio GS1 scaffold with pure `FF30` discovery mapping.
Matches are unverified Cbio / SiSensing candidates because GS1 and GS3 share
the UUID. It declares no sensor capabilities and fails scan/connect without transport
access. It is not registered in any app build. Local SiSensing GS1/GS3 APK
evidence and a Mac GATT connection do not prove glucose compatibility. The
offline plaintext parser returns raw ACK/record fields, never normalized
glucose; unsupported layouts and unknown counter wrap fail closed. See the
[offline evidence record](testing/cbio-gs1-offline.md).

`cgm_libre2` includes a target-unverified, explicitly bootstrapped Gen1 BLE
receiver. Android private debug builds can use a journaled NFC streaming
operation and encrypted receiver state to select the exact target, reserve
login counters, and verify incoming packet CRCs. Normal builds do not register
this driver. Receiving a valid packet does not establish calibrated glucose
support. A separate GPL reference converter can now be injected by the explicit
private Android `libre_glucose_debug_main.dart` entry point. It requires matching
protected calibration evidence and publishes only provisional current samples
after CRC, age, lifetime, quality, finite-math, and duplicate checks. Normal
`lib/main.dart` has no GPL adapter import. Gen2 and Libre 3 remain absent; no
new production sensor compatibility is claimed. See ADR 0004 before combined
distribution.

The private Libre calibration cache uses authenticated plaintext format v2 to
separate `receiverInitialPatchInfo` (the frozen Bluetooth credential) from
`calibrationPatchInfo` (the NFC patch read with the stored FRAM). Only the latter
decrypts calibration FRAM. Exact bootstrap/UID/receiver-patch binding, matching
model/security/region bytes 0–3, and all three current-patch FRAM CRCs remain
required. The encrypted envelope, Keystore key, and backup-excluded filename
are unchanged. Strict v1 records remain readable, with their single patch
mapped to both roles; reads do not rewrite storage. A later successful explicit
read writes v2 atomically. Older builds reject v2 without deleting it; roll
forward instead of clearing app data or changing the sensor's receiver journal.

`cgm_yuwell_anytime` is a target-unverified protocol and live-session contract.
An explicit private Android debug build can scan, authenticate, initialize,
acknowledge notifications, and synchronize records through a secure,
journaled state machine. It is absent from normal builds. The explicit debug
composition can show only the exact V1150 packed field as provisional
engineering data; the default driver policy publishes no glucose. Its
candidate names, CT5 UUIDs, frame arithmetic, transforms, and record parsers do
not establish Anytime 5P compatibility or reproduce the vendor-native glucose
algorithm. See the physical-evidence and V1150 production-publication gates
before changing that boundary.

Restricted health-state schema three changes history-blob filenames from a
reversible base64 storage key to `history-<sha256>.blob`. Schema-zero/one
embedded histories and schema-two filenames migrate automatically. The rename
is atomic within the restricted directory; a launch interrupted before the
metadata rewrite resumes from either old or new names. If both names exist with
different contents, startup preserves both and fails closed for manual recovery
instead of guessing which glucose history is authoritative.

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
