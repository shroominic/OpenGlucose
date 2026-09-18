# Changelog

## 0.1.0

- Add `CbioSessionEvidence`, `CbioSessionOutcome`, and `CbioWriteKind`: a pure,
  host-tested record of one device-backed session (outcome, classified write
  kinds, record counts and index ranges, bounded timing, closed error taxonomy,
  harness/app identity) whose `invariantViolations()` is the verdict a harness
  asserts. It cannot carry a sensor address, credential bytes, vendor material,
  or a physical glucose unit, and `unitStatus` stays `unverified`.

- Vendor link material (stream key, authentication material, prompt) is supplied
  by an injected `CbioCredentialSource`. Nothing is compiled into the package
  and no value is rendered in `toString`, a snapshot, or an exception.

- Add the vendor V120 read-query builders, a strict `0A` glucose batch decoder,
  and a bounded `CbioGlucoseSyncSession` for live polling and history paging
  with explicit fail-closed states. Records expose raw fields only and are
  never labelled with a unit.
- Add `inspectCbioReply`, a read-only structural inspection of one raw `FF31`
  notification. It reports the plaintext invariants, orientation and constant-mask
  searches, and returns `unresolved` with a null frame for the captured five-byte
  payload. It does not decrypt or reassemble.

## 0.0.1

- Reserve the `cbio` driver contract for offline GS1 research.
- Add app-derived `FF30` discovery candidates and `FF31`/`FF32` UUID constants.
- Keep all capabilities false and fail scan/connect without transport access.
- Add strict offline plaintext ACK and packed-record inspection, with synthetic
  integrity, bounds, bit-field, and counter tests. Raw fields have no assigned units.
- Add synthetic contract tests. No live protocol or glucose support is claimed.
- Add separate offline `08` raw-data, `F0/04` storage, and `F0/03` time parsers
  with exact frame bounds and synthetic rejection tests. Preserve the existing
  generic frame parser contract; no units, epoch, or sensor-state meaning is inferred.
- Add separate offline `F0/02` activation-state and expected `07`/`03` ACK
  inspection. Preserve all state/result bytes without granting write permission;
  test state/control separation and zero-history fields with synthetic fixtures.
