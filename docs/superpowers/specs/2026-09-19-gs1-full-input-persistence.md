# GS1 private full-input preservation

Approved engineering scope for existing PR209. Risk R2 (restricted data and
restart correctness); accountable maintainer `@shroominic`, implementation lane
`fix/gs1-full-input-persistence`, independent review by chief of staff. Base
8733e96. This records the approved private assessment and its clarifying addendum;
the rules below include the final ordering requirement from the orchestrator.

## Purpose and exclusions

Preserve actual seven-field raw08 observations for later, separately verified
decoder research. The current legacy persistence loses temperature and other
fields when converting CbioRawGlucoseRecord to compatibility CgmReading rows.
Keep full records private. No decoder, glucose publication, new BLE operation,
time/era inference, shared UI, cgm_core, probe, native library, signing, device,
build, release, or public raw export change is authorized. No new dependency.
Decoder readiness remains unavailable, regardless of record continuity.

## One atomic envelope

New key: `openHealth.history.cbio.fullRecords.v1.<existing encoded binding>`.
The same restricted history-blob implementation and binding encoder remain in
use. Do not add the new key to the public archive index. Original raw-v1 bytes
and checkpoint remain untouched once the new store capability is selected.
No migration/re-encoding of incomplete old rows, no dual writes and no fallback
to the old writer on error. Existing callers without the optional capability
retain their compatibility path and cannot claim durable full observations.

The package-internal envelope contains fixed schema/driver/raw08 profile,
sensorKey, random128bit lowercase32hex captureId, bootstrap provenance, state,
full records, and current checkpoint. It has two states:

* Pending: zero rows, no current checkpoint. Legacy bootstrap stores its exact
  checkpoint and SHA256 of the original opaque legacy envelope; fresh bootstrap
  has neither. Pending is adoption provenance, not full-observation proof.
* Observing: nonempty rows and required existing-format CbioSessionCheckpoint
  equal to the greatest index/rawTime in the admitted contiguous prefix. First
  observed index/time are fixed by the first full row. Legacy first observation
  must be its admitted bootstrap witness; fresh first observation is index1.

The current checkpoint and rows commit in ONE atomic envelope; never write a
separate pointer/checkpoint. Pending adoption is durably written only AFTER
the old owner drains and the host commits selected-target identity, BEFORE BLE.
`prepareTarget` performs validation reads only. Failed adoption opens no radio.

On restart, valid observing state is authoritative over frozen legacy state;
read its exact current witness again under existing guards, additionally checking
the four observed immutable words. Pending reuses only its bootstrap checkpoint;
legacy pending requires the original blob digest and exact checkpoint unchanged.
Fresh pending rejects a newly appeared legacy blob. Malformed present new state
never falls back to v1 or fresh. Absent new state performs first adoption. This
does not claim detection of arbitrary external deletion of every adoption file.
Existing store recovery can yield old or new COMPLETE state, never mixed rows
and checkpoint. A failed write cannot advance durable progress.

## Identity and raw observations

Exactly one captureId/acquisition lineage per sensor binding. This is not a
physical sensor-era identifier. Never rotate, infer, merge, repair or replace a
lineage because of clock/index changes. Immutable sensor binding, captureId,
profile and bootstrap provenance must survive every write and restart.

Rows use existing CbioRawGlucoseRecord:
`[index,rawTime,reindex,rawTemperature,rawDump,rawPayload,rawProcessed]`.
Do not scale any field or reinterpret rawTime as DateTime. Preserve original
first-observed reindex; it is response-relative and may differ on later queries.
Repeated bound index requires identical rawTime and all four raw words. Validate
full incoming observations before the existing archive duplicate fast path can
discard changed words. Mismatch fails closed, preserves retained bytes, and
creates no new lineage. Existing before-checkpoint/time/admission guards stay.

Only admitted contiguous candidates may advance full-state checkpoints. Gaps,
mid-session legacy prefixes and absent native state never imply decoder readiness.
No automatic backfill is added. One live preservation owner per store+binding;
reject a second live owner. Its serialized drain must finish before handoff.
No cross-process concurrency or distributed lock support is claimed.

## Fixed bounds and failure

* One segment and one pending serialized writer per owner.
* At most65535 rows, index1..65535, rawTime0..4294967295 and each other field
  0..65535; exactly seven integer positions, no coercion/unknown fields.
* Entire UTF8 canonical envelope at most4194304bytes; non-row header at most
  4096bytes. Reject oversize encoded input before JSON decode and reject row
  count/shape before allocating full-record objects. Seven-int tuples consume
  at most49bytes including separator, fitting the full index domain.
* Existing frame/parser512byte reassembly, timing and read budgets unchanged.
* No truncation, eviction, cap increase, segment rotation or checkpoint advance
  on cap breach. Refuse before accepting/committing the exceeding batch.
* Write failure pauses acquisition/poll scheduling, retains the last durable
  envelope and dirty candidate for explicit drain/retry; no unsafe success.
* The codec cap is not an OS pre-I/O allocation guard. Native getString already
  reads a string; no memory isolation claim. Atomic files can require12MiB for
  primary/next/previous plus frozen legacy data. Device headroom is UNKNOWN.

## Verification and review gates

Three independently reviewable tasks: codec, owner/session, app adapter and
integration. Each uses focused RED/GREEN tests, formatting, analyzer and diff
checks. Independent review is required at each boundary. Public package contract
additions are opaque store methods only, with changelog/compatibility notes;
internal envelope/owner types remain unexported. Preserve normalized empty/null
snapshot, export exclusion, lifecycle unknown and unchanged shared UI tests.

Offline evidence does not replace later separately authorized build/device
verification. Do not run make check's build/device lanes in this task, publish
branches, create another PR, or merge. Provide exact source commits and offline
logs to the chief for eventual integration into existing PR209.
