# One-capsule GS1 acquisition recovery

R2; accountable owner: @shroominic. The physical normal39 trace confirmed
`cbio.counter.restart` / `witness-time-mismatch`. This means the restored
timestamp witness cannot authorize continuation. It does not prove a clock
shift or establish glucose decoding. Scope is driver/private persistence only.

## Accepted boundary

Retain legacy and fullRecords.v1 bytes at their original keys. An optional
`CbioRecoveryStore` capability adds one separate recovery.v1 blob per unchanged
sensor binding. Its atomic envelope selects the recovery route and consumes
the one-recovery budget by its presence, even while its fresh capture is pending.
Malformed present recovery state fails closed. Legacy/full-only stores retain
their existing failure behavior. No controller, UI or normalized output changes.

The recovery capsule has schema/profile/binding, closed boundary reason, exact
UTF8 SHA256 references to original full and nullable legacy strings,
and a separately identified fresh `CbioFullRecordState`. It validates originals
against their still-present original keys on every load and before selection.
All predecessor bytes are immutable; subsequent writes change only fresh state.
No predecessor rows, checkpoint or anchor enter the fresh state. The capsule
contains only one successor and cannot rotate. Fresh state keeps existing
65535-row / 4MiB / 4096-byte header bounds. Predecessor strings remain only at
original keys; the fresh state is embedded as JSON without double escaping.
Recovery metadata is bounded to 4096 UTF8 bytes and the complete capsule to
4198400 bytes (4MiB plus 4096). Predecessor validation uses existing state bounds.
Excess fails before writes, never truncates. This is a correctness bound, not
an assertion of device free space. Atomic storage errors leave original routes
authoritative and prevent a successor connection.

## Transition and ownership

Only the exact existing witness-time-mismatch guard can request recovery.
The original session first reaches its unchanged terminal failure. It cancels
timers and pending reads, cancels notification/state subscriptions, and awaits
actual GATT disconnection. A cancellation or disconnect failure forbids recovery.
The cleanup result is retained; disconnect callers await it too.

After successful cleanup and private-state drain, the leased owner rechecks
that no recovery capsule exists and that predecessors match. It atomically
writes a fresh pending capsule before any successor radio connection, then
switches its private route and replaces its acquisition archive with an empty
one. A new `CbioGlucoseSession` owns the successor connection, avoiding reuse of
old reassembly/auth/timer state. The original session forwards successor
snapshots/logs and method calls to its existing host subscribers. A close during
transition prevents the new connection; an already committed pending capsule
remains selected on restart. No sensor storageKey or shared host API changes.

The successor requests fresh raw index1 using existing bounded operations.
Its checkpoint advances only over a complete contiguous prefix. Its later
reconnect uses its own exact witness guard. Any successor witness mismatch
stops without another capsule, predecessor modification, or silent retry loop.

## Acceptance

- Existing failure guard remains observable and exact; no loosened equality.
- Successful recovery retains original byte strings and digests, makes one
  durable pending selection before the second BLE connect, and stores seven
  observed fields only in fresh state; public history/latest remain empty.
- Delayed cleanup blocks new BLE; cancellation/disconnect/flush/write failure
  leaves no successor connection or partial route selection.
- Crash after pending commit resumes the same capture ID with no legacy input.
- Concurrent/stale owners cannot overwrite a selected recovery route.
- Malformed/foreign capsule, altered originals, gaps, conflicting fresh rows,
  byte/row overflow, and second mismatch fail closed without data loss.
- Legacy stores and full-only stores retain their prior contract.

No build, phone action, commit or publication before independent review.
