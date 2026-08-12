# Health-data recovery and erasure

Owner: data owner, with privacy review. OpenGlucose currently has no verified
full backup/restore or delete-all feature; do not promise either to users.

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

Stop sensor/background writers first. Remove all sensor histories, selected
sensor, native background target/payload, notifications/live activities,
journal/database, AI artifacts/key, exports, preferences, and caches. Relaunch
offline and verify that no record is restored. Document any OS/provider copy
outside app control and the user action required there.
