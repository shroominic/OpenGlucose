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
- `package:cgm_cbio/cgm_cbio.dart` (private raw acquisition; normalized glucose unavailable)
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

`cgm_cbio` 0.1.0 implements authenticated direct-BLE raw acquisition in private
driver state. Its public normalized snapshot has no latest reading, empty
history and rawHistory, zero/unknown history counters, and no decoded-history
or raw-history capability. The normal
platform registry includes it only when its vendor credential source is
configured; builds without those values omit it. `FF30` discovery still
identifies an unverified Cbio / SiSensing candidate, not an exact model or
software version: GS1 and GS3 share that UUID. Exact-model admission and
calibrated glucose compatibility remain unverified.

The permitted routine session writes are authentication and read queries.
Fresh startup, reconnect and recovery never write the sensor clock. Activation,
reset, calibration, threshold, key-registration and firmware operations are not
enabled. Raw samples, checkpoint/clock details and
acquisition counters remain inside the driver and restricted private storage;
they are not published as `CgmReading` values, advertisement glucose, or public
diagnostics. GS1 uses the unchanged shared normalized AiDEX/Libre2 presentation,
including its empty, error and unknown-lifecycle states. There is no GS1 raw-value,
support-reference or recovery dashboard. Neither the raw integer nor its
historical `/10` engineering representation is verified mg/dL or mmol/L.
Synthetic normalized UI fixtures prove presentation parity, not actual decoding
or production glucose support.

The additive optional `CbioFullRecordStore` interface extends the existing
opaque `CbioPrivateStateStore` with `readFullRecords`, `writeFullRecords`, and
`legacySha256` (lowercase SHA256 over the exact original UTF8 envelope). Hosts
without this capability retain their legacy compatibility path, which does not
preserve all raw08 inputs. The app implements it using its existing crypto
dependency and restricted history-blob store, without a new public raw API.

For capable stores, original `openHealth.history.cbio.v1.<identity>` bytes and
checkpoint are frozen, never migrated into fabricated full rows or dual-written.
The separate `openHealth.history.cbio.fullRecords.v1.<identity>` key stores one
pending/observing envelope, all seven observed integer fields, and the current
authoritative checkpoint atomically. Its captureId identifies an acquisition,
not a physical sensor era. Pending adoption records exact legacy SHA256 and
bootstrap checkpoint or explicit fresh provenance; observing state preserves
the first witnessed prefix and first-observed response-relative reindex.
Preparation is read-only. Old-owner drain and existing in-memory target selection
precede durable pending adoption, which precedes BLE. Durable selected-sensor
promotion remains later and unchanged. An unused pending binding cannot supply
another binding's checkpoint. Malformed present state never falls back to v1.

The fixed bounds are 65535 rows, 4194304 UTF8 envelope bytes and 4096 header
bytes. There is no eviction, truncation, cap increase, automatic backfill or
lineage rotation. Failed writes pause acquisition and retain dirty candidates
without advancing durable progress. Native atomic replacement may require
12 MiB plus frozen legacy data; actual device/storage headroom is unknown.
These additions preserve input, not decoder readiness or calibrated glucose.

The additive `CbioRecoveryStore` capability extends `CbioFullRecordStore` with
atomic `readRecovery`/`writeRecovery`; the app uses the separate restricted
`openHealth.history.cbio.recovery.v1.<identity>` key. Only the existing exact
witness-time-mismatch guard authorizes one independent acquisition after
successful notification/state cancellation, GATT disconnect and private drain.
A pending capsule must commit before the successor connects at raw index1.
Original fullRecords and legacy bytes stay immutable at their existing keys,
validated against exact UTF8 SHA256 references. No old rows/checkpoint/anchor
enter the fresh capture. Existing host session subscriptions/methods continue
through forwarding; no controller or shared domain API changes are required.

Presence selects this route and consumes its sole budget across restart, even
while pending. Malformed state, changed originals and a second witness mismatch
fail closed; there is no lineage rotation. Fresh state keeps the bounds above;
recovery metadata is limited to 4096 UTF8 bytes and the complete capsule to
4198400 bytes. Failure never truncates state. Legacy/full-only stores keep their
previous contract. Older builds ignore the new route, so downgrade after
selection is unsupported; retain the complete restricted store and roll forward.
Each fresh, reconnect and recovery session remains read-only after
authentication and rechecks its own exact witness. Fresh epoch-less records do
not create a wall-clock anchor; an existing stored anchor is reused only while
every covered raw timestamp matches its exact anchor witness. Another mismatch
can stop acquisition. This capability establishes neither continuity with the
predecessor nor calibrated glucose or physical reconnect reliability.

The driver owns raw checkpoint/history in a versioned restricted envelope and
requires exact input-witness proof before merging a resumed suffix. The app's
private-state adapter preserves original legacy blobs/indexes and durably copies
their descriptors into a private migration manifest before changing public
routes. Shared normalized history uses a separate sensor-bound namespace.
Malformed state and counter-era conflicts fail closed without deleting the
old data. Downgrades do not understand this envelope and are not a supported
recovery path. See [durable history and recovery](testing/cbio-gs1-durable-history.md).
Sensor start, warmup, activation and expiry are not inferred from raw history.
The actual driver publishes null start/elapsed values, so the shared lifecycle
policy displays unknown without inventing sensor age or expiry. Legacy non-null
defaults are not evidence of a verified lifecycle. Normalized synthetic GS1
records follow the same lifecycle policy as other sensors; actual model/lifecycle
verification remains incomplete.

Production polling has no cumulative lifetime read cap. Individual operations
remain bounded, manual/automatic requests are paced and coalesced, and an
explicit optional bench cap pauses reads. `maxReadsPerSession` is now nullable;
callers must handle null as unlimited. This does not establish overnight,
screen-off or reconnect reliability on a physical phone. Historical
[offline evidence](testing/cbio-gs1-offline.md) is not the current driver boundary;
the [release-readiness plan](superpowers/plans/2026-09-19-cbio-release-readiness.md)
records remaining decoder, model, lifecycle, artifact and device gates.
The shared UI also retains inherited narrow hero overflow and Chinese timeframe
segment clipping observed in control sensors; presentation parity is not a
claim that those baseline layout limitations are resolved.

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

That explicit debug composition can also inject additive private raw-record
durability. Credential schema v1 remains readable for authentication but does
not authorize restore. Schema v2 binds the exact sensor-key digest, verified
firmware, opaque generation, history opcode, and record layout. Recovery starts
at history index zero, compares every durable record and empty slot in
quarantine, and only then fetches and commits the suffix. Conflicts preserve
the old blob and fail closed. This path does not register Yuwell in normal
builds, enable normalized Anytime glucose, or establish physical restart
durability; an authorized process-kill/restart device test remains pending.

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
