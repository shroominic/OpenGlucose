# ADR 0006: Commit Libre observations and readings together

- Status: Proposed; implemented for private validation, pending maintainer review
- Date: 2026-09-10
- Owner: `@shroominic`
- Risk: R2 data migration; no new RF command or distribution authority

## Context

Accepted-reading history cannot prove which rejected or warmup sensor minutes
were already observed. An in-memory frontier is lost on restart. Writing a
frontier before debounced app history would create a new failure: a crash could
suppress a replayed minute although its reading was never saved.

## Decision

Use one app-owned restricted history repository. The Libre adapter and controller
share its serialized read/merge/encode/write queue. At the existing active
history key, one atomic envelope contains the exact saved-bootstrap/model
binding, observed-minute frontier, clear tombstone, and accepted readings.
The pure protocol contract carries normalized readings, never raw packets,
receiver credentials, or decoder code.

The driver loads this state before RF, restores history only, and commits every
new CRC-validated minute together with its optional accepted reading before
live publication. Rejected/warmup observations still advance the durable frontier.
The bounded queue cannot extend freshness: the deadline starts at packet receipt.
Cancellation prevents late live publication but does not cancel an issued write.
Any uncertain write quarantines that driver and history identity; RF cleanup is
still attempted. Display retains only the repository's last confirmed data.

Normal Disconnect archives only observations not already in that exact
bootstrap's saved segments and removes selection, but keeps the active
observation envelope. A no-new-data disconnect creates no segment. Existing
archives are immutable; a receipt-clock collision allocates an unused opaque
segment discriminator, not a fabricated activation or reading time. Aggregate
storage counts deduplicate old overlapping Libre segments within a bootstrap,
never between different sensors.

Clear history removes readings, not replay state. An unbound legacy identity
with active or archive-only readings cannot report a successful clear until its
real receiver binding can establish a tombstone. Archive/clear operations must
not let a successful deletion race with a later stale archive snapshot.
Delayed controller snapshots cannot restore cleared data or overwrite a newer
driver commit. History without a selected pointer requires explicit Connect;
it cannot automatically select a sensor.

Connection selection is separate from numeric readiness. A fresh newly
committed observation supplies closed selection evidence even during warmup or
without an accepted glucose result. Restored history, repeated minutes, pending
or failed transactions, and stale timing supply no new evidence. This does not
change glucose display, wellness, export, or live-surface eligibility.

## Alternatives

A native frontier plus normalized-reading outbox would need a second durable
schema and acknowledgement protocol. The existing atomic per-history blob can
provide the same completed-commit boundary with one owner. Separate frontier
and history writes, or accepted-history-only reconstruction, do not meet it.

## Separate NFC history evidence

The app-owned import foundation adds a lazy schema-two envelope for fresh NFC
history. Schema-one loads and current-only Bluetooth commits retain their
previous format until a successful NFC import or the BLE backfill upgrade below.
This is a storage/control boundary, not a claim
that NFC backfill is physically verified or enabled in a normal release.

`observedMinute` remains Bluetooth evidence. `lastNfcScanMinute` is separate
historical acquisition evidence. The conservative replay barrier covers both,
retained sample minutes, and the clear tombstone, but must not create current
glucose, freshness, lifecycle, or new-selection evidence. Thus an outage import
can include minutes newer than the last Bluetooth packet without inventing a
live packet. A scan cannot regress behind the frontier at ticket issue or the
last committed NFC scan. A repeated scan age is a no-write no-op.

Every schema-two reading retains a separate immutable acquisition origin,
first receipt, and timestamp basis. NFC trend/history samples preserve their
provisional vendor source and use the scan receipt minus the exact sensor-minute
offset as their historical timestamp. Overlap never changes a saved reading's
first receipt, value, flags, origin, or timestamp. Schema-one records migrate
with unknown acquisition origin/basis and no inferred first receipt; their
existing reading timestamps remain unchanged. Only exact committed `bleLive`
entries can confirm current glucose after this migration. Historical origins
cannot satisfy the controller's current-reading confirmation rule.

An opaque single-use ticket must be issued before the fresh read, with the exact
receiver binding, repository/process owner, connection owner, and clear revision.
Ticket issue, imports, live commits, clears, and archive writes use the same
queue. The host bounds a ticket to at most three minutes and permits at most five
seconds of wall/monotonic clock drift. These are defensive host limits, not
sensor-protocol timing claims. Admission checks the receipt interval and checks
the deadline again immediately before the write. Cancellation reaches queued
work immediately, but does not undo a dispatched durable write. Clear is the
ordered deletion operation; its persisted revision and conservative tombstone
prevent a late pre-clear read from restoring data. Imported candidates are
bounded to 16 trend and 32 history entries; duplicate identities are rejected.

New archives from schema-two state use a bound provenance envelope. They obtain
the complete authoritative retained delta, not a stale Bluetooth-session list.
Strict archive readers retain acquisition metadata and validate identity,
binding, counts, and schema. Existing list archives are never rewritten. A
missing active envelope cannot be reconstructed as a Bluetooth frontier from
NFC archive samples. Generic list writers cannot erase archive provenance.
The archive export reader resolves the exact persisted manifest reference;
it does not join active history or fall back to legacy output after a malformed
provenance record. Its immutable export model keeps each reading paired with
its evidence through sorting and isolate transfer. Existing CSV, TXT, and XLSX
APIs retain byte-compatible 13-column v1 output. Acquisition-bearing v2 output
appends four columns: `export_schema_version`, `acquisition_origin`,
`first_received_at_utc`, and `timestamp_basis`. A missing legacy receipt stays
blank, and value source is unchanged. Neither sensor identifiers nor raw
protocol frames are added to the file. The serializers, strict repository,
and actual compute/share UI path have passing tests; broad software checks
also pass. This implementation does not close the physical-import or release
gates.

## Sparse Bluetooth history

The optional decoder contract can supply nine historical slots separately from
the current sample. The existing private converter already decodes them; the
transport does not gain a conversion formula or a new sensor command. The six
older trend positions are 2, 4, 6, 7, 12, and 15 minutes behind the packet age.
The three history positions start at `((age - 2) ~/ 15) * 15`, then step back
15 and 30 minutes. Only these bounded positions are admitted. Per-slot rejected
values and samples before warmup are omitted, not interpolated. A rejected
current value does not invalidate an otherwise valid historical slot.

A newer packet commits its observed frontier, optional current reading, and
accepted historical batch in the same transaction. Historical timestamps use
the original packet receipt minus the exact sensor-minute offset. New
`bleTrend` and `bleHistory` acquisition origins retain that receipt and the
`sensorRelative` basis; they never establish live glucose, current freshness,
or new-selection evidence. Deduplication preserves the first saved acquisition
and the clear tombstone excludes old backfill. Repeated/regressed packets do
not refill history or refresh any receipt.

This requires an explicit schema-three active/archive envelope. Schema two
requires a genuine NFC scan minute and must continue to reject the new BLE
origins. Schema three permits a null NFC scan minute, so a BLE-only history
does not fabricate an NFC read. Reads do not eagerly migrate either older
format; a successful BLE-history commit performs the upgrade. Later NFC
imports, clears, and archives must not downgrade it. Export schema v2 remains
the same 17-column format with the two additional acquisition-origin values;
its version is independent of the storage-envelope version.

This is sparse packet backfill, reaching roughly 32–46 minutes behind a mature
packet. It is not the longer NFC ring, continuous outage recovery, or a new
`syncHistory` RF operation. Synthetic software tests cannot replace a hardware
comparison of packet positions and NFC history.

## Consequences and controls

Legacy accepted readings for the exact bootstrap provide only a lower-bound
frontier. They cannot recover rejected minutes. Once bound, the envelope is the
sole authority; old archives cannot override a clear tombstone. The native
receiver journal and existing ordinary/archive lists remain unchanged. New
schema-two and schema-three active/archive records require readers for those
formats; a schema-two-only, schema-one-only, or list-only writer cannot safely
downgrade newer state. Re-enrollment is a different
identity, not replay-safe continuity of the same physical sensor.

Tests cover accepted/rejected/warmup restart, commit-before-pointer recovery,
stale writes, deletion, clock rollback, legacy/corrupt/future/binding cases,
uncertain storage, and close during a pending commit. Native atomic-file recovery
tests remain required. This decision does not solve receiver-lease crash recovery,
first enrollment, decoder validation/licensing, or release qualification.
