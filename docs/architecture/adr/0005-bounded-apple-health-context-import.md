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
opaque anchor per type in a separate versioned import-state file. The iOS
directory, file, and transaction artifacts are backup-excluded before use. A
binary that does not recognize a future import-state schema fails closed and
does not rewrite it. This keeps the import cursor separate from the strict
sensor/glucose restricted-state schema and permits a safe app downgrade.
Draft builds that wrote an import cursor into the strict v3 file discard that
cursor during upgrade and repeat a bounded source read; source-aware upserts
make that replay safe. They do not migrate opaque anchors across the two state
contracts.

The app persists samples/tombstones and then purges only Apple Health records
that have fallen before the current 30-day predicate before it persists that
type's next anchor. This explicit source/type-scoped expiry handles the fact
that an anchored query with a moving date predicate cannot later report every
deletion for an aged-out record. If the purge or local state write fails, that
type's anchor does not advance; a later user-triggered sync safely repeats the
bounded work.

The UI distinguishes an unavailable device, a locked device, a retryable
failure, a read-access request, a ready state, and **No accessible data**. It
must not claim that a read permission was granted. Missing
`HKMetadataKeyWasUserEntered` is retained as an unknown recording method, not
assumed to be automatic.

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
- On each successful sync, the importer expires source/type records that fall
  before that sync's rolling 30-day cutoff without fabricating a source
  tombstone. Turning the toggle off does not itself erase retained context.
- A full native page can require another explicit sync; the UI states this
  conservatively instead of starting a hidden long-running import.
- Turning the toggle off stops future app reads. It does not delete retained
  local imported context; verified deletion remains separate work.

## Follow-up controls

- Establish source-overlap and display policy before rendering imported context
  behind glucose data.
- Decide retention beyond the current 30-day bounded window and complete local
  deletion for imported context.
- Add reviewed background-delivery policy only after explicit user controls and
  physical-device evidence.
- Evaluate Health Connect separately; it must not reuse iOS authorization or
  anchor assumptions.

## Required physical-device evidence before broader rollout

This partial implementation is not evidence-complete until a real iPhone with
Health data records each case below without copying values or identifiers into
test logs or issue comments:

- opt-in and off behavior, including the native authorization sheet;
- an empty or unreadable read shown only as **No accessible data**;
- HealthKit unavailable, a locked device, and a retryable native error mapped
  to their safe public states;
- sleep, workout, and heart-rate import with a source revision/update and a
  returned deletion;
- a record that ages out of the 30-day predicate removed before its next anchor
  advances, including an interrupted/retried sync; and
- backup exclusion for the import-state directory, primary file, and staging
  artifacts, plus an update/downgrade/roll-forward check that preserves an
  unknown future state file.
