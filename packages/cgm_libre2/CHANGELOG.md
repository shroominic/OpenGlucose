## Unreleased

- Keep one cancellable filtered advertisement scan for an earned durable
  recovery when its sensor is absent. Revalidate the exact receiver after
  return and confirmed scan cleanup, before any connection or counter use.
  Initial/no-store setup stays bounded; native failures and cancellation stop
  the wait. No repeated login, NFC command, or schema change is added.
- Allow durable sessions to earn a further bounded link recovery after three
  fresh committed observations over two monotonic minutes on the replacement
  connection. Require recent, contiguous evidence; never use replay, imported
  history, wall-clock changes, or a pending commit. Preserve all exact-owner,
  cleanup, fresh-advertisement, and new-counter gates. No-store callers keep
  the one-recovery limit; the diagnostic attempt count is now cumulative.
- Extend the optional decoder result with separately typed sparse BLE history
  and the observation store with an atomic historical-reading batch. Validate
  exact packet positions and preserve receipt-relative timestamps, first
  acquisitions, and provisional vendor quality. Historical samples cannot
  become current data; rejected current values can still retain valid older
  slots. Store implementations must accept the new `historicalReadings` named
  argument. No new RF command or bundled glucose algorithm is added.
- Add an optional observation-state replay barrier separate from the live BLE
  observed minute. Hosts can import newer NFC history without creating live
  freshness; restored or concurrently imported history excludes older packets.
  Reject inconsistent advanced commit acknowledgements before publication.
- Parse bounded Gen1 NFC FRAM trend/history rings from the all-three-CRC-verified
  type. Preserve raw quality/error/temperature fields and sensor-relative
  minutes, omit unfilled slots, and reject uncertain age/index timing rather
  than shift a historical identity. This MIT-only parser performs no glucose
  conversion, timestamp inference, persistence, NFC operation or live update;
  app backfill integration and physical qualification remain separate work.
- Publish a closed committed-observation marker for a fresh, newly persisted
  Libre packet, independent of glucose acceptance. Hosts can retain a verified
  warmup/decoder-free connection without promoting it to numeric readiness.
  Restored history, replayed minutes, stale timing, failed commits, and the
  no-store compatibility path do not supply this evidence.
- Add an app-injected `LibreGen1ObservationStore` for atomic observed-minute
  and normalized-reading retention. Durable mode requires the store; existing
  no-store private/test callers remain in-process only. Completed atomic
  commits protect the same saved bootstrap across restart, including warmup
  and rejected glucose. Legacy accepted history supplies only a lower bound,
  not complete pre-upgrade replay coverage or continuity across re-enrollment.
  Restore history without current freshness; bound the observation queue and
  storage deadline, preserve first receipt, and prohibit late live publication
  after close. Any uncertain commit blocks reuse of that driver instance while
  physical cleanup is still attempted. No raw capture, GPL decoder code,
  receiver/counter format, sensor command, or production enablement changes.
- Append closed `bluetoothOff`, `permissionRequired`, `bluetoothUnavailable`,
  and `scanFailed` failures. Preserve typed scan/adapter errors and distinguish
  early scan termination from the actual advertisement deadline. Do not copy
  arbitrary native messages or change connection retry authority.
- Parse sensor-relative BLE age and FRAM age/lifetime from the CRC-validated
  Gen1 types, independently of optional glucose conversion. FRAM lifecycle
  remains an observation at read time; zero lifetime is unknown. No UTC
  activation timestamp, sensor stop, or state-changing authority is inferred.
- Publish observed BLE age in live session information even without a decoder
  or after glucose rejection. Require decoder age to match the wire age, and
  consume each observed minute before conversion so rejected/warmup packets
  cannot be replayed as new readings through the bounded recovery. Clear live
  timing/current data after ten minutes without a newer observed minute and
  on disconnected/control snapshots. Timing freshness can only be shortened.
  Same-bootstrap restart protection now requires the observation-store contract
  above. Fresh FRAM integration and physical timing validation remain separate
  release work; no receiver storage format changes.
- Retain closed pre-login transport diagnostics, including the exact known
  Android GATT 133 classification, without copying native error text or
  arbitrary codes. Retry policy, user-facing failure text, and login/counter
  behavior are unchanged; status 133 does not establish a bond problem.
- Expose read-only `LibreGen1PatchInfo.sensorVariant` from existing accepted
  model signatures. Live snapshots retain the identified variant; no region or
  revision is inferred. Plus/offline identification does not grant live support.
- Correct every live/control snapshot to use the declared 14-day lifetime and
  60-minute warmup; no session start or elapsed time is inferred.

- Declare the optional sensor-neutral data profile: 60-minute warmup, 14-day
  nominal lifetime, receipt-timed first-accepted history, live-only current
  readings, and reported-only lifecycle. This adds no lifecycle evidence,
  backfill, NFC command, or production sensor-support claim.
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
  uncertain login. The durable stable-reception renewal above supersedes the
  original one-recovery lifetime bound; a lone packet still cannot renew it.
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
