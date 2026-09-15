# Implement a sensor driver

Use one protocol package with the shared app, chart, archive, diary, and export
boundaries. Implement sensor differences in driver contracts and trusted app
composition, not scattered manufacturer checks. Start with the
[protocol investigation workflow](sensor-protocol-workflow.md); this guide maps
verified behavior into code. [ADR 0005](../architecture/adr/0005-sensor-data-and-setup-policies.md)
records the current abstraction and its limits.

## Boundaries

| Layer | Owns | Must not own |
| --- | --- | --- |
| `cgm_core` | Readings, snapshots, capabilities, data policies, optional operation contracts | BLE/NFC commands, keys, Flutter, vendor decoders |
| `cgm_ble` / platform adapter | Scan and transport lifecycle, native BLE translation | Glucose interpretation, sensor activation policy |
| `cgm_<vendor>` | Classification, protocol state machine, normalized records, data profile | App widgets, native plugin calls, mandatory cloud accounts |
| App composition and native setup adapter | Driver registration, connection policy, permission UI, NFC ownership and protected journals | Guessed glucose conversion or unreviewed sensor commands |
| Shared app | Persistence, chart/diary, capabilities-based controls, freshness and quality display | Inferring one vendor's clocks or reset procedure for another |

The shared scan registry owns one physical scan. A pure classifier returns a
`DiscoveredSensor` only for a verified supported branch. Stable `driverId`,
`storageKey`, and `deviceId` have different purposes: routing, persistent sensor
identity, and transport targeting. Do not reuse another driver's persistent
identity or treat an ambiguous advertisement as a writable target.

## Record observed variants without changing authority

Use optional `CgmSessionInfo.sensorVariant` for observed model, protocol, and
revision evidence. Archives can retain it; discovered and selected-sensor
identity remain unchanged. Keep Software Revision separate from Firmware
Revision, and leave region unknown without an evidenced mapping. See the
[variant contract and current branch matrix](sensor-variants.md).

A variant descriptor does not select a driver, profile, decoder, or activation
policy. The driver still performs its existing identification and command
checks. Unknown revision strings remain descriptive data; do not add speculative
blocking or silently change old reading semantics under the same identity.

## Declare data meaning before returning readings

Implement the optional `CgmSensorDataProfileProvider` on the driver. For a
receiver that records receipt-time samples, a declaration can look like this:

```dart
static const dataProfile = CgmSensorDataProfile(
  warmupMinutes: 60, // Replace with verified exact-model timing.
  expectedLifetimeMinutes: 14 * 24 * 60,
  timestampBasis: CgmReadingTimestampBasis.receivedAt,
  duplicatePolicy: CgmHistoryDuplicatePolicy.keepFirst,
  currentReadingPolicy: CgmCurrentReadingPolicy.liveOnly,
  retainedLifecyclePolicy: CgmRetainedLifecyclePolicy.reportedOnly,
);

@override
CgmSensorDataProfile get sensorDataProfile => dataProfile;
```

This is a policy example, not timing evidence for an unknown sensor. The
existing `legacy` profile retains old API behavior; do not use its 60-minute /
15-day defaults as research findings. Current declarations are:

| Driver | History handling | Lifecycle from retained records | Declared warmup |
| --- | --- | --- | --- |
| AiDEX / LinX | Session-timed; corrected records replace earlier records | Existing timestamp/minute inference retained | 60 minutes |
| Private Libre Gen1 | Acquisition-relative: live receipt or historical receipt minus sensor offset; first accepted minute/source stays unchanged; live current sample required | Reported only | 60 minutes |
| Private Yuwell | Session-timed; existing replacement behavior retained | Reported only, due to its clock offset | 45 minutes |

These declarations describe current code, not a new sensor-support claim.
Use `CgmSessionInfo` for observed session start, elapsed minutes, warmup, and
lifetime. Do not populate a session start from a receipt timestamp when the
clock relationship is unknown. Default timing does not establish current
lifecycle. A receipt-time profile cannot enable retained lifecycle inference,
even if its inference-policy field is set incorrectly. The same applies to
`acquisitionRelative` profiles. Do not relabel older packet samples as current
receipt-time observations, or infer an activation time from their offset.

The app resolves a registered provider before the compatibility catalog.
When adding a driver, add its read-only profile to the app catalog if old
archives must remain readable while that driver is disabled. New archive
segments also save their reported warmup. A stable driver identity must not
silently change the meaning of old stored readings.

## History is not the same as backfill

- A separate transport can need a separate explicit history operation. The
  Libre Gen1 implementation uses a controller-owned Bluetooth pause, an NFC
  session with no activation authority, and a single-use repository import
  ticket. Normal `syncHistory` capability remains false for its BLE session.
  A terminal read/import result is not RF cleanup proof: its owner must stop
  and dispose the reader before releasing the pause. Retain unknown ownership
  after a failed or timed-out stop, and never silently reset a receiver.
- Keep imported history acquisition distinct from current data. Preserve the
  first receipt, sensor-relative sample time, source, and quality through
  archives. NFC scan age may advance an exclusion barrier, but must not become
  live BLE age, freshness, or selection evidence. Clear invalidates older
  import tickets. Do not relabel a cached calibration image as a fresh scan.
- `snapshot.history` can contain samples received during a live stream even
  when `capabilities.supportsHistoryBackfill` is false.
- A live packet may already contain older samples. Keep them separate from the
  current result, validate the exact protocol slots, and commit the accepted
  batch with the packet frontier. Preserve its original receipt, per-slot
  rejection, first acquisition on overlap, and clear tombstones. The Libre
  implementation demonstrates sparse trend/history slots with no extra RF
  command. It must not fabricate a scan age or overwrite NFC provenance to fit
  an older storage schema. Test both rejected-current/valid-history packets and
  malformed batches, plus storage acknowledgements below the UI history limit.
- `supportsHistoryBackfill` aliases the existing serialized `supportsHistory`
  flag. Set `supportsHistory: true` only when the driver can actually request
  past sensor data; the alias itself is read-only.
- Implement `syncHistory` with the driver's safe cursor and completion rules.
  Document how its optional normalized offset maps to wire records. Do not
  assume every record is one minute or every protocol index is a sensor age.
  Preserve unresolved gaps; zero received records is not proof of full sync.
- Define duplicate identity and correction semantics. The current app key is
  sensor minute plus source, or timestamp plus source when no minute exists.
  If that cannot represent the protocol, propose a tested identity contract
  before using fabricated minutes or changing stored records.
- Preserve UTC instants and provisional/source flags through persistence.
  Current-reading eligibility, chart retention, and wellness/export eligibility
  are separate checks. A valid CRC or successful connection is not enough to
  publish a numeric glucose value.
- Normal link recovery and app restart retain the active recording segment.
  Explicit Disconnect archives a snapshot. Libre writes only observations not
  already archived for that exact bootstrap and skips an empty delta; it keeps
  the active durable history and replay frontier after selection is removed.
  An explicit reconnect restores that history without current data. Existing
  Libre segments stay unchanged, including after receipt-clock rollback.
  For a known session start, rearchiving the same session can update its
  existing archive. Test the protocol's session identity and merge behavior;
  do not assume every disconnect creates a new physical sensor session.
- A replay frontier and its optional reading must share one durability boundary.
  Do not save a frontier first and rely on a later UI debounce for the reading.
  The Libre reference uses one app-owned repository and atomic envelope. Loads,
  merges, clears, and observation commits share its queue. Test uncertain writes,
  controller cancellation, clear tombstones, and historical migration; a write
  timeout is not cancellation. See [ADR 0006](../architecture/adr/0006-atomic-libre-observations.md).
  Check archive-only legacy history before claiming a clear succeeded. Without
  a verified receiver binding, accepted legacy points cannot become a valid
  replay tombstone. Serialize or exclude concurrent clear/archive operations.
- Treat verified connection selection and numeric readiness as different
  decisions. For Libre, only a fresh, new, completed observation transaction
  supplies the closed committed-observation marker used to retain warmup or
  decoder-free selection. Restored history, GATT setup, and a replay do not.
  The app still requires the existing quality and current-reading checks before
  it can display or export glucose. Test both the initial session snapshot and
  later stream events; the stream need not replay its last event to a new listener.

## Connect and custom setup

Register the driver and its classifier in `driver_factory_io.dart`. Set the
registration's trusted `connectionPolicy`:

| Policy | Shared Connect behavior |
| --- | --- |
| `explicitConnect` | Allows the existing driver's reviewed activation behavior for this explicit action; AiDEX uses it |
| `separateConfirmation` | First connects without activation; a reported activation-required state can lead to separate confirmation; Yuwell uses it |
| `externalSetupOnly` | Ordinary and saved connections never grant activation; Libre uses its separately authorized NFC flow |

The registry default and unknown-driver policy are `externalSetupOnly`.
Advertisements or saved metadata cannot opt into a more permissive policy.
The policy is not sensor-operation authority by itself: protocol/native code
must still enforce its own exact-target, state, journal, and one-shot rules.
Restore, retry, and background recovery must not grant new activation intent.

Keep uncommon setup behind explicit model help on the Bluetooth-first page.
For another NFC or custom flow, implement a specialized app/native adapter
with bounded start, status, cancel, and closed progress. It must reject stale
callbacks, wrong targets, expired evidence, and ambiguous cleanup. Return a
prepared `DiscoveredSensor` to the shared connection flow only after verified
setup and confirmed ownership handoff. The existing Libre implementation and
its injection seams are examples, not a generic ready-made NFC engine.
Never return “connected” merely because a tag vibrated or a setup step passed.

Use existing optional contracts for other operations: calibration capabilities
gate its controls; `CgmBondTransferSession` represents its reviewed Bluetooth
bond procedure, not a universal unbind API. A protocol that moves receivers by
another method needs its own reviewed contract. Unsupported operations must
remain unavailable, not succeed as no-ops or reuse AiDEX commands.

## Contributor checklist

1. Add a pure driver package and synthetic protocol tests. Follow dependency
   and license policy before adding packages, code, or reference vectors.
2. Declare the data profile; test its no-I/O getter and exact-model constants.
3. Register the driver only in the intended build, with a pure classifier,
   data profile resolution, and explicit connection policy. Keep existing
   driver registrations working.
4. Test the shared app with a synthetic non-vendor driver ID. Verify that
   semantics, not names, select duplicate, current-reading, lifecycle, and
   activation behavior.
5. Test archived warmup boundaries, restart with saved data, inactive-driver
   archives, uncertain cleanup, stale samples, and capability visibility.
6. Run package tests, app regressions, analysis, formatting, affected builds,
   and the repository `make check` contract. Record any gate not run.
7. Capture and independently review the real-device sequence in the
   [workflow](sensor-protocol-workflow.md). A unit test is not RF evidence.
8. Update package/root changelogs, compatibility, ownership, exact-model
   support/evidence, and recovery/release notes before requesting review.

Do not add production support flags until the model, decoding, lifecycle,
recovery, privacy, license, and release gates are satisfied. New abstractions
must preserve those gates, not bypass them.
