# ADR 0004: Preserve source-aware import identity locally

- Status: Accepted
- Date: 2026-08-24
- Owners: `@shroominic`

## Context

Health platforms can return the same activity, sleep, or heart-rate record in
more than one bounded read. They can also revise a record or report its
deletion after the initial import. The previous local repository appended every
sample, which made repeated imports duplicate data and discarded the source
details needed to explain or reconcile it.

The source record identifier, source app/package, device details, and revision
are restricted health metadata. They are necessary for correct local
reconciliation, but must not become logs, exports, analytics, or default UI.

## Decision

Add optional typed provenance to normalized activity, sleep, and heart-rate
samples. Provenance contains a platform-scoped stable external identity, source
application/package, source name/device, recording method, and source revision.
The normalized sample itself remains the authoritative observed interval.

The SQLite store uses a partial composite unique index per sample family:
`(platform, external ID)`. A provenance-bearing sample therefore replaces the
same source record. Manual and legacy samples have no import identity and keep
their append-only behavior. A batch containing the same imported identity more
than once is rejected before it can create order-dependent results.

Source deletions use a separate typed tombstone contract. Applying a tombstone
removes the matching visible sample and retains the platform identity and
revision locally, even if the platform did not return the original values or
interval. A later source record with that identity clears its matching
tombstone.

Schema version 2 adds nullable identity columns and the tombstone table without
rewriting or deleting schema-version-1 rows. The migration is performed by the
SQLite upgrade transaction. A prior schema-version-1 binary can still read the
JSON sample payloads after this upgrade, but it cannot preserve the new import
identity when it writes; do not continue imports on a downgraded binary. Roll
forward to a schema-version-2 build before importing again. The schema-two
migration probes existing columns and tables before adding them, because a
schema-one binary can lower SQLite's version marker while leaving the additive
schema-two shape in place. Rolling forward restores the marker and does not
repeat an `ALTER TABLE`; it does not restore provenance omitted by a
schema-one write. Schema-two binaries reject future unknown schema versions
instead of lowering their version marker.

## Alternatives considered

- Compare normalized values and timestamps for deduplication: rejected because
  distinct records can legitimately share values and timestamps, while revised
  records can change either.
- Append a deleted sample with fabricated values: rejected because a platform
  deletion may contain only an identity and should not invent health data.
- Add native HealthKit or Health Connect import in this change: rejected. This
  decision establishes the local contract first; permission UI, platform
  readers, anchors, and source-overlap policy remain separate work.

## Consequences

- Repeated imports can be deterministic only when the platform provides a
  stable external identity.
- Existing records remain readable and are not retroactively guessed into
  identities.
- Importers must apply platform changes in source order and use the tombstone
  API for deletions.
- Source identifiers remain local-only restricted metadata and are excluded
  from default timelines and exports.

## Follow-up controls

- Persist one incremental anchor/cursor per platform and data type.
- Define and test source-priority and overlap rules before aggregate analytics.
- Add bounded native importers and permission UI with physical-device evidence.
- Add app-lifetime repository lifecycle and recovery ownership at composition.
