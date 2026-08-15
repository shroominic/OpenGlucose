# ADR 0006: Coordinate complete local-data deletion through a dry-run contract

- Status: Accepted
- Date: 2026-08-15
- Owners: `@shroominic`

## Context

OpenGlucose stores restricted data across SQLite context records, alert
history, optional AI artifacts and secure keys, sensor state/history blobs,
archive manifests, native background surfaces, and temporary/derived files.
Clearing one screen or one sensor is not complete erasure. A destructive path
also needs a preview, explicit consent, interruption handling, and proof that
the stores are empty.

## Decision

`cgm_core` exposes `LocalDataDeletionCoordinator` and a
`LocalHealthDataDeletionBackend` adapter contract. `createPlan()` inventories
all known domains without mutation. The plan includes a stable non-sensitive
fingerprint and an exact confirmation phrase. `dryRun()` reports the proposed
scope, and `execute()` refuses missing confirmation or a changed inventory,
then deletes and verifies domains one at a time. Any failure stops subsequent
work and returns a partial, non-complete result.

The default domain set includes journal/context records, AI insights/API key,
alert history, active sensor state, sensor archive, background surfaces,
derived caches, and temporary exports. Existing UI is not wired to execute this
contract implicitly. Platform adapters remain responsible for stopping writers,
clearing secure/native stores, and implementing a complete post-relaunch
verification before the product can claim erasure.

## Consequences

- Users and reviewers get a deterministic, inspectable deletion report before
  any destructive operation.
- A stale plan cannot erase a changed store under an old preview.
- Partial failures are honest and recoverable, but the adapter must provide a
  retry/repair UI before calling the workflow complete.
- The in-memory backend and tests provide deterministic contract evidence
  without using health data or platform storage.
