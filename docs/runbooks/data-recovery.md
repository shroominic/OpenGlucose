# Health-data recovery and erasure

Owner: data owner, with privacy review. OpenGlucose has a core deletion
coordinator contract, but the production store adapter and user confirmation
flow remain release work; do not promise verified delete-all until those checks
are complete.

## Recovery

1. Preserve the original app container or user export read-only where possible.
2. Record app/schema version, platform/OS, sensor identity needed for matching,
   time zone, and failure symptom without copying health values into tickets.
3. Never restore by editing live preferences or a production database. Work on
   a copy with approved tooling.
4. Validate structure, schema/version, timestamps/offsets, units, stable IDs,
   counts, and integrity before showing a preview.
5. Require explicit user confirmation, import idempotently, and reconcile
   duplicates/partial writes. Keep rollback evidence until verification passes.
6. Verify relaunch, representative dates, latest/stale state, metrics, and
   deletion. Securely remove temporary plaintext copies.

A future recovery bundle must be encrypted, authenticated, versioned, portable,
and tested across supported schema versions. OS cloud backup remains disabled
for Android health data. On iOS, verify that restricted state remains in the
dedicated application-support file and that startup confirms its
backup-exclusion resource attribute. A failed migration or exclusion check is
a release blocker.

## Erasure

Use `LocalDataDeletionCoordinator` as the single orchestration boundary. First
call `createPlan()` and show the returned non-sensitive counts and domains in a
confirmation preview. A dry run must not mutate anything. Execution requires
the exact plan confirmation phrase; a changed inventory invalidates the plan.

The complete default scope is:

- journal events and imported activity, sleep, and heart-rate samples;
- AI insights and the secure BYO API key;
- alert history;
- active sensor state and every restricted reading history blob;
- sensor archive manifests and archived reading blobs;
- native background/live surfaces, derived caches, and temporary exports.

The app adapter must stop sensor/background writers before invoking the plan,
delete each domain through its durable store, verify it empty, and stop on the
first delete or verification failure. A partial result must remain visibly
incomplete and must never be reported as erasure. Relaunch offline and verify
that no record is restored. Document any OS/provider copy outside app control
and the user action required there (for example, Apple Health data written by
an earlier explicit export).
