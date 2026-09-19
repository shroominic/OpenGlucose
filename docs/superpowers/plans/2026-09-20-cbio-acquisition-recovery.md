# GS1 Acquisition Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Parent coordinates independent review; no additional reviewers are spawned.

**Goal:** Resume bounded raw acquisition once after a confirmed timestamp-witness conflict while preserving every predecessor byte.

**Architecture:** Add one optional private recovery-store capability and one strict capsule codec. The existing full-record owner selects/persists its fresh inner state under a separate atomic key. The failed session awaits complete cleanup and starts a distinct successor session, forwarding through the existing session interface.

**Tech Stack:** Pure Dart driver, existing Flutter private adapter, existing atomic restricted history store; no dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-cbio-acquisition-recovery-design.md`

## Global Constraints

- Worktree `release-v040-main-reconcile`, branch `feature/cbio-gs1`; preserve untracked user report.
- No UI/controller/core API changes, sensor writes beyond existing setup/read flow, normalized readings or inferred timestamps.
- Original legacy/full keys unchanged; one durable recovery capsule, no rotation/eviction.
- Full inputs max65535 rows / 4MiB; capsule max4198400 UTF8 bytes, metadata max4096; predecessor bytes never copied into capsule.
- Tests precede implementation; no build/phone/commit until independently reviewed.

## Task 1: Atomic optional recovery persistence

Files: `packages/cgm_cbio/lib/src/cbio_private_state.dart`, new
`cbio_recovery_state.dart`, `cbio_full_record_owner.dart`,
`cbio_private_state_owner.dart`, their focused tests; app
`openhealth/lib/src/persistence/cbio_private_state_adapter.dart` and adapter test.

Interfaces:

```dart
abstract interface class CbioRecoveryStore implements CbioFullRecordStore {
  Future<String?> readRecovery(String sensorKey);
  Future<void> writeRecovery(String sensorKey, String envelope);
}
// Owner API: canRecoverWitnessMismatch and Future<void> recoverWitnessMismatch().
// Recovery presence selects the fresh inner full state and permanently consumes budget.
```

- [x] Add failing real-owner regressions for exact originals, one pending capsule,
  fresh index1 admission, restart identity, second recovery refusal, altered
  predecessors, malformed capsule, failed write and competing owners.
- [x] Run package focused test and record RED before implementing interfaces/codec.
- [x] Implement strict closed-key codec, exact predecessor/digest validation,
  fresh inner state, bounded encoding and optional owner routing. Existing lease
  covers original and successor routes; recovery transition drains before write.
- [x] Add adapter test: `expect(store.values, {...before, recoveryKey: capsule})`;
  observe missing-method RED, implement separate bound private key, verify no
  selected-sensor or original-key changes and atomic failure behavior.
- [x] Run focused package and Flutter adapter tests, format/analyze; parent review.

Task1 verified: package328 passed/2 existing skipped before review; app46 passed;
review regression/fix expanded focused owner+codec coverage to50 passing.
Independent review approved after concurrent close/recovery failure retained
dirty writes, released clean ownership and preserved the original error.

## Task 2: Guarded successor session

Files: `packages/cgm_cbio/lib/src/cbio_glucose_session.dart` and its existing test.

Interfaces: consume Task1 owner transition; use a new `CbioGlucoseSession` with
same sensor/transport/credentials/timing/clock and recovered private owner.
No changes to `CgmSession` or host subscription APIs.

- [ ] Add RED session regression with two fake connections: first same-index
  different-time witness, second fresh index1 batch. Assert first disconnect
  completes and recovery pending commit precedes second connect, original bytes
  unchanged, successor inputs persisted, no normalized reading.
- [ ] Add delayed/throwing cleanup and write failures; assert connect count stays
  one. Add close-during-transition and second-mismatch/restart cases.
- [ ] Retain/await failure cleanup future and its success result. On eligible
  mismatch only, drain, commit recovery, then create successor and forward its
  snapshots/logs. Close races check closing before connection and release owner
  only after transition settles. Old async tasks remain terminal and cannot
  mutate successor state or public output.
- [ ] Run full package tests plus enabled trace session tests. Verify original
  failure still logged once and successor failure cannot allocate another route.
- [ ] Update README/changelog, compatibility and durable-history documentation
  to describe one-capsule opt-in capability, bounds and unsupported downgrade.
- [ ] Format, analyze, run relevant app adapter/integration tests and diff checks;
  parent performs independent review before build/commit/phone operations.
