# ADR 0006: Persist Yuwell raw history as a private contiguous prefix

- Status: Accepted
- Date: 2026-09-21
- Owner: `@shroominic`
- Risk: R2 health/device data and serialized local state

## Context

The Anytime driver keeps exact authenticated history records and all-FF empty
slot observations in process memory. Process death discards both collections,
so the next session cannot distinguish a previously consumed empty slot from a
true history gap and restarts paging at index zero.

The pure Dart vendor package must remain independent of Flutter storage. The
app already has an atomic, backup-excluded restricted history-blob store. Raw
records must not enter the normalized repository, `CgmReading`, UI, export,
analytics, or decoder paths.

Saved communication credentials and a locally generated token do not prove an
immutable physical wear or record era. A sensor reset or lifecycle transition
cannot be ruled out from check-ID alone.

## Decision

The vendor package owns an additive schema-v1 `YuwellRecordState` envelope and
`YuwellRecordStateOwner` persistence boundary. The envelope stores one strict
contiguous prefix from index zero. Each slot is either the exact authenticated
11-, 15-, or 17-byte record for the bound layout or an explicit consumed all-FF
empty slot. An FC terminator is never stored or counted.

The envelope is bound to the fixed driver ID, a one-way selected-sensor binding,
exact verified firmware, a 128-bit local persistence generation, and the exact
history opcode/layout. The local generation namespaces storage; it is not
sensor-emitted era evidence. A domain-separated SHA-256 key over the selected
storage key and generation gives each generation a separate app blob, leaving
older generations untouched.

The owner validates the whole envelope before use, accepts each complete parsed
history batch atomically, serializes immutable whole-envelope writes, and
advances durable revision only after a successful write. It flushes after 16
newly consumed slots, after a larger completed frame, at history-cycle
completion, and on explicit disconnect drain. A failed write retains dirty
in-process state and the prior durable blob; it never deletes, truncates, or
repairs stored state automatically.

On restart, matching stored state remains quarantined. The driver must re-read
history from index zero and compare every durable record and empty slot before
trusting the cursor and requesting the suffix. Early termination, a missing
slot, or any record/empty/byte mismatch preserves the prior blob and fails
closed. This costs radio time proportional to the durable prefix but avoids
inventing sensor-era certainty.

Secure credential schema v2 will add exact verified firmware and the local
generation in the integration delivery. Schema v1 remains readable but cannot
authorize raw restore. A v1 saved session may upgrade only after the existing
read-only version query and unchanged authenticated check-ID succeed; no new
activation, configuration, pairing, or other state-changing command is added.

## Alternatives

- Keep records only in process memory: rejected because restart loses exact raw
  history and FF slot continuity.
- Persist through the normalized health repository: rejected because raw
  authenticated protocol evidence is not validated glucose and must remain
  private.
- Add a vendor-specific database: rejected because atomic whole-envelope blobs
  fit the bounded state and the app already supplies the required restricted
  storage semantics.
- Put all records in secure credentials: rejected because Keystore/Keychain
  credentials are for small bootstrap identity, not bounded history payloads.
- Trust check-ID plus a local random token as a sensor era: rejected because
  neither is source-backed immutable wear evidence.
- Re-read only the durable tail: rejected for this delivery because source does
  not establish a defensible tail witness that rules out every earlier-era
  mismatch.

## Consequences and follow-up controls

- A process can lose at most the uncommitted suffix under the 16-slot policy;
  the next process revalidates the complete durable prefix and re-fetches that
  suffix.
- Live records ahead of the history prefix remain bounded in memory until a
  matching history frame consumes their slots; they never advance durability.
- Malformed, future-schema, oversized, foreign, or conflicting state fails
  closed without overwrite or deletion.
- Raw blobs are additive and ignored by older builds. Credential schema v2 and
  driver/app composition must ship together; downgrade must reject unknown
  secure credentials rather than corrupt them.
- Task 1 supplies only the pure package codec/store boundary. App durability is
  not claimed until credential, driver, adapter, restart, and failure tests in
  the integration delivery pass.
- Physical process-kill/restart proof remains a separate release gate.
