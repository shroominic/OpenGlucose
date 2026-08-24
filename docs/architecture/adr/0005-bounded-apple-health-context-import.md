# ADR 0005: Use bounded anchored Apple Health context import

- Status: Accepted
- Date: 2026-08-24
- Owners: `@shroominic`

## Context

OpenGlucose needs optional local context for sleep, workouts, and heart rate.
An initial full HealthKit read can be large, repeat records on every retry, and
miss source deletions. Apple does not disclose whether read access was granted;
an empty read and an unavailable read can look the same to an app.

The source-aware identity and tombstone contract from ADR 0004 is the required
storage dependency. HealthKit UUIDs, source app/device metadata, and anchors
are restricted health metadata. They must not enter logs, exports, analytics,
or default UI.

## Decision

Use an iOS-only native `HKAnchoredObjectQuery` channel for these exact types:

- sleep analysis;
- workouts; and
- heart rate.

The user must enable the separate context-import toggle and then press
**Import now**. Each request has a rolling 30-day range. Dart rejects ranges
over 31 days, and the native channel repeats that bound before querying.
No background observer or automatic import is started.

The native channel returns a versioned, fail-closed payload. It maps each
HealthKit UUID to a typed Apple Health import identity, retains local-only
source provenance, and returns deletion UUIDs as tombstones. There is one
opaque, restricted-state anchor per type. The app persists samples/tombstones
before it persists that type's next anchor. A malformed persisted anchor is
cleared and requires a later user-triggered bounded retry; an unknown native
failure retains its anchor.

The UI distinguishes an unavailable device, a read-access request, a ready
state, and **No accessible data**. It must not claim that a read permission was
granted.

## Alternatives considered

- Use Flutter's generic Health package for all reads: rejected because this
  scope requires iOS anchored changes and deletion records.
- Read every HealthKit record without a date predicate: rejected because the
  user action would be unbounded.
- Treat an empty response as permission denial: rejected because HealthKit
  intentionally does not reveal read authorization.
- Add Health Connect, historical glucose import, overlays/charts, or source
  precedence here: rejected as separate product and safety decisions.

## Consequences

- Repeated source records replace local rows by stable identity rather than
  duplicating them.
- Returned source deletions remove visible imported rows through tombstones.
- A full native page can require another explicit sync; the UI states this
  conservatively instead of starting a hidden long-running import.
- Turning the toggle off stops future app reads. It does not delete retained
  local imported context; verified deletion remains separate work.

## Follow-up controls

- Establish source-overlap and display policy before rendering imported context
  behind glucose data.
- Decide retention and complete local deletion for imported context.
- Add reviewed background-delivery policy only after explicit user controls and
  physical-device evidence.
- Evaluate Health Connect separately; it must not reuse iOS authorization or
  anchor assumptions.
