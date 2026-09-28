## Unreleased

- Return a closed `cleanupUnconfirmed` error from explicit disconnect when
  physical scan/connection cleanup fails or times out. Preserve the terminal
  snapshot/history and quarantined lease; repeated calls do not retry or clear
  uncertainty after a late completion.
- Collect accepted current readings in immutable, bounded in-session history,
  preserving original receipt UTC times, provisional quality, and sensor-minute
  deduplication across the one guarded recovery. Retain prior points without
  asserting a healthy current reading on rejection, expiry, or disconnect.
  This adds no sensor backfill, inferred start time, persistence, or export.
- Permit one guarded replacement after a previously validated stream is
  physically disconnected: await confirmed cleanup, reread the exact bootstrap,
  require a fresh advertisement, and reserve a new counter. Never retry an
  uncertain login or replenish the recovery budget after a packet.
- Add an optional independently supplied current-sample decoder contract, with
  no bundled algorithm. Reject warmup, invalid age/lifetime, mismatched sample
  age, non-finite values, and duplicate minutes across recovery. Accepted
  readings are vendor-source, receipt-timed, raw-free and display-provisional;
  decoder errors do not stop validated transport or leak private error text.
- Wait up to 150 seconds for a fresh exact-target FDE3 advertisement before
  connecting, allowing for observed two-minute burst gaps. Reject cached,
  undated, mismatched, or future observations; do not retry after the deadline.
- Require an explicit single-attempt BLE transport capability through all
  wrappers. Never fall back to the default connection or retry a physical
  connection within an attempt.
- Complete scan cancellation before connection; retain the session lease if
  scan cleanup is uncertain, with deterministic timing/cancellation tests.
- Cover read-only bootstrap restore, cleared stale targets, durable counter
  advancement after an unknown login, and historical-only saved lifecycle with
  regression tests. Restore does not repeat NFC setup or infer a countdown.
- Add an explicitly NFC-bootstrapped Gen1 BLE driver using the existing
  `cgm_ble` and `cgm_core` workspace contracts. Match the exact response-derived
  target, reserve counters durably before one F001 write with response, persist
  its outcome before F002 subscription, and reject stale callbacks and retries.
- Expose closed connection and CRC-validated packet diagnostics without
  interpreting raw ADC values as glucose. Preserve a failed-cleanup lease and
  require a new explicit connection after exhausted recovery or unknown login.
- Add strict algorithm-order UID and six-byte Gen1 patch-information types.
- Add the independently reusable, pure Libre 2 Gen1 primitive, exact 43-block
  FRAM decryption with all-three-region CRC validation, and exact 46-byte BLE
  decryption with CRC validation.
- Add pure activation, enable-streaming, and with-response F001 login plans.
  These plans perform no I/O and remain target-unverified, state-changing R3
  inputs for a separately gated adapter.
- Add a pure, closed Gen1 lifecycle parser that accepts only an all-three-CRC
  verified decrypted FRAM value, returns no source bytes, and does not authorize
  state-changing behavior.
- Add a read-only validator for one explicit owner-private Gen1 FRAM capture.
  It uses descriptor-bound `O_NOFOLLOW` access, binds the direct algorithm-order
  UID, UID-derived manufacturer prefix, and patch metadata, rejects escaped
  duplicate keys, checks all three FRAM CRCs, and emits one neutral result.
- Accept the collector-bound explicit Libre 2 lifecycle capture schema v2 in
  the offline validator, preserving exact v1 validation. Reject unbound v2
  sources, malformed attempt metadata, extra fields, and escaped duplicate
  keys; apply the same identity, patch, and three-region CRC checks.
- Add the pinned MIT LibreTools Example2 vector to prove direct Android UID
  order passes all CRCs while reversed order fails.
- Add deterministic synthetic vectors, malformed-input, per-region integrity,
  counter-range, immutability, and diagnostic-redaction tests.
- Preserve the pinned LibreTools and DiaBLE MIT notices in
  `THIRD_PARTY_NOTICES.md`.
- Add a pure, one-action-at-a-time Gen1/Gen2 live handshake planner.
- Add typed BLE, NFC bootstrap, authorization, and verified-session boundaries
  without concrete I/O or cryptography implementations.
- Add the exact audited Gen2 `0x20` challenge-request action while leaving its
  target write mode explicitly unresolved.
- Reject unknown generations, unsupported topologies, stale callbacks, and
  out-of-order input without automatic retries.
- Add synthetic handshake, redaction, disconnect, and fail-closed tests.

## 0.1.0

- Add target-unverified SAS and GKS UUID/topology classification.
- Add observation-only Gen1 and Gen2 reference state sequencing.
- Add strict Gen2 session-information and encrypted composite assembly.
- Add immutable typed events, redacted typed errors, deterministic tests, and
  an explicit no-crypto/no-I/O safety boundary.
