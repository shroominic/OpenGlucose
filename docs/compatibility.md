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

Durable Libre sessions can earn another bounded link recovery after three
fresh committed observations span two monotonic minutes on the replacement
connection, with contiguous minute/receipt evidence still recent at disconnect.
The no-store compatibility path retains one lifetime recovery. No public
constructor or persisted schema changes; `cgm.libre2.recoveryAttempts` is a
cumulative diagnostic count rather than a zero/one value. Callers must not use
that count as receiver authority. Each attempt still requires confirmed cleanup,
the same bootstrap, a new advertisement, and a fresh durable login count.

An earned recovery in durable mode now waits on one cancellable filtered scan
until the sensor returns, instead of treating the initial advertisement deadline
as a terminal failure. Initial setup and no-store callers retain that deadline.
After return, an additional exact-bootstrap read must succeed within 15 seconds
before connection. The closed `cgm.libre2.waitingForReturn` marker affects only
presentation, not authority or persisted formats. Native scan termination,
permission/radio errors, cancellation, and unknown cleanup still stop recovery.
This extends the passive wait, not the number of permitted login attempts.

The private Libre app retains accepted current and bounded older packet samples
in restricted history, preserving provisional/source fields and first
acquisition for a repeated sensor minute. Older packet samples use the original
receipt minus their exact sensor-minute offset; they are not current glucose.
This adds no manual calibration. Provisional/raw samples remain available in charts and explicit
archive export. Source quality is shown in the `Data quality` row in Current
sensor and archive details, while home uses normal connection status and reading
time without bench/body warnings. This presentation change does not alter
source/provisional flags or export disclosures. The samples remain excluded
from wellness/AI aggregates, Apple Health, and numeric live surfaces. Sensor
placement is not a runtime mode or a data-quality rule. Saved Libre receipt
records cannot infer a session start or automatically expire its receiver.
This policy adds no production compatibility claim and does not change
receiver/counter formats.

CRC-validated Libre Gen1 packet age now supplies current `elapsedMinutes`
independently of glucose conversion. The driver clears it on disconnected or
stale observations and requires a newer minute before refreshing its deadline.
The app can display nominal remaining life without creating a UTC activation
time; age alone cannot retire the receiver. With the injected durable observation
store, completed commits retain the frontier across sessions/processes using
the same saved bootstrap. FRAM timing is a
separate read-time parser and cached factory evidence is not current lifecycle.
No receiver, counter, or archive schema changes for this slice.

Active Libre history now uses a strict schema-one observation envelope at its
existing qualified history key. One restricted-store transaction contains the
receiver/model binding, highest observed sensor minute, clear tombstone, and
optional normalized reading. This does not change the native file-store schema
or ordinary/archived reading-list formats. Before its first bound envelope,
migration uses retained accepted readings for the exact bootstrap as a lower
bound; rejected/warmup observations from older builds cannot be reconstructed.
Legacy local receipt strings retain their previous local-time interpretation;
new envelopes serialize the same instants with an explicit UTC zone. Repeated
minutes cannot change their first receipt. A bound clear tombstone cannot be
repopulated from older controller snapshots or archives.

Downgrade to a list-only Libre writer is unsupported after this migration: it
cannot preserve the replay frontier. Retain a private pre-update backup and roll
forward instead. Unknown schema/binding/corrupt state is not overwritten. An
uncertain write blocks that history identity and driver until a real store/app
restart can recover disk state. Re-enrollment creates a new bootstrap identity
and is not covered by same-bootstrap replay protection. See
[ADR 0006](architecture/adr/0006-atomic-libre-observations.md).

The app-owned NFC history import foundation lazily upgrades an active Libre
envelope to schema two only on a successful fresh-read import. Existing
schema-one loads and current-only Bluetooth writes do not eagerly migrate it. Schema two
separates the Bluetooth observed minute from the NFC scan minute and exposes a
conservative replay barrier; imported outage readings may be newer than the
last Bluetooth packet without supplying live freshness. Per-reading acquisition
origin, first receipt, and timestamp basis are immutable and separate from
`CgmReading` source/provisional quality. Existing schema-one timestamps survive
unchanged, with unknown acquisition provenance rather than an inferred upgrade
to live Bluetooth evidence. Only exact committed Bluetooth-origin entries may
confirm current readings in schema two.

The import requires a pre-read, single-use, exact-owner/binding ticket and shares
the atomic repository queue with live commits, clear, and archive operations.
The host's maximum three-minute ticket interval and five-second wall/monotonic
drift tolerance bound admission; they do not claim protocol timing support.
Clear covers both frontiers and imported points, invalidates pre-clear tickets,
and retains a versioned clear revision. A failed or uncertain import write
quarantines authority rather than permitting a later stale overwrite.

New schema-two Libre archive envelopes preserve acquisition provenance; old
archive lists and their bytes remain unchanged. Strict archive readers support
both formats. A schema-one-only app cannot read or safely rewrite the new active
or archive envelopes, so downgrade after the first NFC import is unsupported.
Keep the private pre-update backup and roll forward. Missing active schema-two
state is not recreated from NFC archive points as invented Bluetooth history.

Sparse BLE history uses schema three, with the same acquisition-entry shape
and a nullable NFC scan minute. A successful BLE-history batch lazily upgrades
the active record; later NFC imports/archives preserve that version. Older
schema-one/two records remain readable and are not rewritten by a load.
Schema two still requires a real NFC minute and rejects the new `bleTrend` and
`bleHistory` origins. Only `bleLive` can confirm current glucose. Clear barriers,
first acquisition, unknown-state protection, and atomic durability are retained.
Schema-two-only builds cannot safely downgrade schema-three data. Keep the
private pre-update backup and roll forward. The export format remains v2 with
17 columns; the storage version and export version are separate contracts.

`LibreGen1ObservationStore.commit` adds the optional `historicalReadings` named
parameter. Implementers must accept it and atomically merge the bounded batch
with the packet frontier and optional current sample. Existing decoder results
default to no historical samples. The driver/package change adds no dependency,
RF command, receiver format, or production support claim.

`CgmReadingTimestampBasis.acquisitionRelative` is an additive core enum value
for mixed live-receipt and historical receipt-minus-offset samples. Exhaustive
consumers must handle it; it never permits retained lifecycle inference. The
private Libre profile uses it without changing `CgmReading` JSON.

Archive export now supports both formats without changing existing output.
The existing CSV, TXT, and XLSX APIs remain byte-compatible 13-column v1.
Acquisition-bearing exports use additive 17-column v2: the same 13 columns,
followed by `export_schema_version`, `acquisition_origin`,
`first_received_at_utc`, and `timestamp_basis`. The export reads the exact
persisted manifest reference and keeps each reading paired with its evidence
in one immutable snapshot, including during sorting. It does not join active
history, infer a missing receipt, or change the reading's value source. Unknown
legacy receipts remain blank. Sensor identifiers and raw protocol frames are
not export columns. Strict repository and actual compute/share UI tests pass,
as do the broad software checks recorded in the release-readiness document.
This foundation alone adds no sensor compatibility or physical-backfill claim.

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

### Default-off Android read-only NFC integration

`openGlucoseLibreNfcReadOnly=true` is an explicit native Gradle option, not
normal Libre sensor support. It selects one recorder-free Gen1 lifecycle reader
and excludes the debug reader owner. The main manifest declares optional NFC;
phones without NFC retain the existing Bluetooth experience. Strict native
capabilities control the existing inline NFC UI. No new native dependency,
platform floor, receiver migration, raw log, activation, streaming, glucose
decoder, or iOS NFC backend is enabled. Existing private receiver/capture state
blocks this slice without mutation. Physical validation and the remaining
receiver/distribution work are tracked in the
[production integration map](testing/libre2-production-integration.md).

The same selector additionally permits an exact saved-receiver channel in
Android debug. Generic setup still refuses prior private state; a separate
history purpose admits only the unchanged confirmed receiver after BLE cleanup.
It reuses the current 16 read commands and the existing atomic history formats;
it does not enroll, alter counters, migrate credentials, or add release support.
Normal main remains decoder-free. Only the existing explicit private glucose
entry can supply the adapter without capture, and that selection fails startup
when native receiver capability is unavailable. See the
[receiver/history contract](testing/libre2-receiver-integration.md).

### Additive sensor policy contracts

`CgmSensorDataProfileProvider` is optional; the required `CgmDriver` and
`CgmSession` APIs are unchanged. AiDEX, private Libre, and private Yuwell now
declare their data semantics. A registered provider wins over the read-only
app compatibility catalog; the catalog does not enable a disabled driver.
Unmigrated third-party drivers retain the explicit legacy data profile. New
drivers must declare their own verified timing and lifecycle interpretation.

`supportsHistoryBackfill` is a getter alias for `supportsHistory`; serialized
capability and reading keys are unchanged. Connection activation policy comes
from trusted app registration, not persisted/discovered metadata. The default
denies ordinary connection-time activation. Existing AiDEX and Yuwell policies
are registered explicitly; Libre keeps its separate authorized NFC setup.

New archive entries include an optional nonnegative `warmupMinutes` value from
the session. Existing entries are read without rewriting and use their driver's
compatibility profile. This corrects the old universal 60-minute archive
filter, including Yuwell's valid minutes 45–59. Older apps ignore the new field
and can display their previous filtering policy; a forward build restores the
corrected behavior without changing reading values. Receiver journals, login
counters, reading JSON, history blob keys, and active-selection formats do not
change. See [ADR 0005](architecture/adr/0005-sensor-data-and-setup-policies.md).

### Descriptive sensor variants

`CgmSessionInfo.sensorVariant` and `ArchivedSensorSession.sensorVariant` are
optional. They separate model, region, hardware, firmware, software, and
security-generation evidence without changing `driverId`, discovery JSON,
history identity, profiles, capabilities, decoders, or receiver journals.
Missing fields remain unknown. Existing connected-device checks remain the
authority; stored text cannot widen protocol or operation support.

The archive JSON field is additive and lazily written with new session metadata.
Old records load without an eager rewrite. Old apps ignore the descriptor and
may discard it when rewriting a manifest; reading data remains unchanged, but
lost descriptive evidence cannot be recovered by a later upgrade. Preserve the
restricted container before a downgrade when that evidence matters. New apps
retain the descriptor when re-archiving the same session without new identity
evidence. Unknown serialized source values become `unknown`; malformed text is
discarded under the documented bounds. No schema-wide migration is required.

AiDEX's legacy `firmware` field still contains the existing Software Revision
read; the descriptor and current settings label that value as software. Libre
now reports the same 14-day nominal lifetime in its live snapshots as in its
declared profile. That profile correction does not establish session start or expiry,
new regional compatibility, or Plus support. See the
[variant guide](development/sensor-variants.md).

### Release support

The OpenGlucose app remains pre-1.0. User-facing behavior can change between
minor development releases, but data loss, silent semantic changes, reduced
platform support, or removed privacy/safety controls are never treated as
casual changes. Record them prominently with migration or recovery guidance.

Only the latest tagged release and `main` receive best-effort fixes. See
[SECURITY.md](../SECURITY.md) for security support and
[ADR 0003](architecture/adr/0003-platform-release-model.md) for release
traceability.
