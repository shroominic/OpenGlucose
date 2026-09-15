# ADR 0005: Declare sensor data and connection policies

- Status: Accepted
- Date: 2026-09-09
- Owner: `@shroominic`
- Risk: R2; no new RF command or production sensor support

## Context

One application must host different sensor timelines and setup procedures.
AiDEX can download session-timed history and correct its time anchor. The
private Libre path retains received samples, cannot backfill missing intervals,
and must preserve the first receipt of a repeated minute. Yuwell declares a
45-minute warmup, not the previous archive default of 60 minutes. Its protected
activation clock and record clock also need distinct interpretation.

Vendor checks in the controller hid these differences. Boolean capabilities
alone cannot express timing or duplicate semantics. Conversely, making every
protocol step a generic command would remove the exact-target authorization,
native ownership, and durable unknown-outcome guarantees of custom setup.

## Decision

1. Add pure-core `CgmSensorDataProfile` and the optional
   `CgmSensorDataProfileProvider`. A driver declares model timing defaults,
   timestamp basis, duplicate policy, current-reading policy, and whether
   retained samples can infer lifecycle. The getter performs no I/O. Live
   `CgmSessionInfo` remains the source of actual session timing; a profile
   alone cannot establish activation, warmup completion, or expiry.
2. Resolve profiles through the trusted driver registry. The controller uses
   them for live/history projection, restore, inferred expiry, and archives.
   Existing drivers without this optional interface retain legacy behavior.
   A narrow read-only compatibility catalog supplies known profiles when a
   driver is not enabled. It grants no connection authority. New archived
   segments preserve their reported warmup so filtering does not depend on a
   future installation still containing their driver.
3. Keep operation capabilities separate. `supportsHistoryBackfill` is an
   additive alias of `supportsHistory`, not a second switch: it describes
   sensor download, not local retention. Calibration uses its existing
   capability, and reviewed Bluetooth bond transfer uses the optional
   `CgmBondTransferSession`. Local disconnect is not transfer or reset.
4. Add app-owned `SensorConnectionPolicy` to each registration. An ordinary
   explicit connection can allow activation, require separate confirmation,
   or defer setup to an external/custom flow. The default denies activation.
   Discovery/persisted metadata cannot select this policy. Restores and
   reconnects do not become activation permission.
5. Keep custom protocol state machines and native bridges specialized. The
   shared UI selects the trusted policy and renders common connection states;
   the Libre adapter still owns NFC proof expiry, cancellation, journals,
   exact-target checks, and safe handoff. No `execute(string)`, arbitrary frame
   interpreter, generalized token generator, or automatic command replay is
   introduced. A future custom adapter must preserve those boundaries before
   it can return a prepared sensor to the shared connection flow.

## Compatibility and limits

The existing `CgmDriver`/`CgmSession` required interfaces, reading JSON, history
keys, receiver storage, and operation journals do not change. The archive's
optional nonnegative `warmupMinutes` field has a legacy fallback and needs no
eager rewrite. Older apps ignore the field and can display an older warmup
policy; use a forward build for the corrected archive behavior.

This is a first implemented abstraction layer, not a claim that all vendor
checks are gone. Protocol diagnostics, platform-specific availability, and
native setup remain explicit. The legacy profile is a compatibility bridge,
not a recommended default for a newly researched sensor. New drivers must
declare and test their own policy; uncertain clocks use reported-only
lifecycle. Different model semantics require a reviewed separate profile/driver
identity, not an undocumented change under an existing archived identity.

No new backfill, transfer, calibration, NFC backend, platform, or release
capability is enabled. Existing sensor and distribution gates remain in force.

### Model, regional, and revision evidence

Add optional `CgmSensorVariant` in session information and archived session
metadata. It records a driver's descriptive identification source, protocol
family, model discriminator, region, security generation, and separate hardware,
firmware, and software revisions. Unknown axes stay null; opaque revision text
is not ordered or treated as a support range. Discovery and stored descriptors
never select activation policy, a decoder, or a data profile.

AiDEX supplies observations from the reads it already makes; its legacy
`firmware` alias remains compatible while the descriptor calls `2A28` software.
Libre supplies only its existing allowlisted patch identification. Three
Libre 2 Gen1 signatures remain eligible for the protected live path; the two
Plus signatures stay offline-only. Country is not inferred from patch bytes.
See the [variant matrix](../../development/sensor-variants.md).

This small contract has actual display/archive consumers. A universal variant
resolver, speculative firmware allowlist, or automatic fallback between security
branches is not introduced. A future variant with different data semantics
still needs a reviewed stable profile/driver identity and storage plan.
Archive addition and downgrade limits are in the compatibility policy.

The variant audit also found that Libre live snapshots still inherited the
generic 15-day session lifetime. They now use the driver's declared 14-day
profile and 60-minute warmup in every attempt/control snapshot. That correction
alone did not establish session start or elapsed time.

The later MIT timing parser (2026-09-10) supplies current sensor-relative age
from CRC-validated BLE packets without glucose conversion or a UTC start.
The driver owns its monotonic observation deadline and clears stale/control
age. Shared presentation uses that age without wall-clock extrapolation;
nominal age-only expiry does not authorize automatic retirement. The separate
FRAM parser is read-time evidence, not permission to use cached calibration as
current lifecycle. Cross-process observed-frontier persistence remains open.

## Alternatives

- More vendor checks in UI/controller: rejected; shared behavior would require
  a new conditional for every sensor and archive.
- Replace all session APIs with a universal workflow engine: rejected; too much
  scope and no safe common authorization model for sensor-changing commands.
- Persist all protocol policies with every reading: rejected; changes storage
  and migration without a present need. Preserve normalized readings and the
  small archive timing fact needed by an actual consumer.

## Verification and follow-up

Test profiles on real driver classes without RF; test shared behavior using a
synthetic driver ID with the same semantics. Cover corrected and repeated
minutes, history-only snapshots, restart, unknown lifecycle, archive boundaries,
unavailable drivers, conservative setup defaults, and existing AiDEX/Yuwell
activation behavior. Run workspace checks and affected builds. Device evidence
from before this refactor remains historical, not validation of the new build.

Follow the [driver guide](../../development/sensor-driver-guide.md) and
[protocol workflow](../../development/sensor-protocol-workflow.md). Future
history cursors, richer lifecycle provenance, setup adapter extraction, and
neutral recovery descriptors need concrete consumers and their own tests;
they must not be inferred from a capability name.

### Implementation checkpoint

Implemented in the isolated `codex/libre-readiness` worktree, continuing the
recorded `164b170` base and preserving earlier private Libre repairs. Synthetic
tests cover all three actual driver declarations and arbitrary driver IDs,
profile routing without I/O, first-receipt retention, current-data suppression,
reported-only lifecycle, archive timing, and trusted activation policy.

Independent review found a connecting-placeholder bug: failed reconnect still
used 60-minute defaults and could archive that value for a 45-minute sensor.
Its new regression failed before the shared placeholder helper and passes
after it. All app-owned restore/connecting/interrupted-transfer placeholders
now use the resolved timing profile. The helper does not fabricate elapsed
time or sensor state. Both review findings (this bug and overgeneralized archive
wording) are resolved; no P0/P1/P2 finding remains in the reviewed slice.

Local checks passed 1,099 unit/widget tests, the discovered integration test,
all eight analyzers, formatting, and the capture/release/tooling contracts.
Android debug and web builds passed. The web build emitted a missing
Cupertino-font warning; no font or asset dependency changed in this slice. These are
dirty-worktree checks, not clean CI or a full `make check` result. iOS/macOS,
signing, and physical sensor revalidation of this refactor were not run. No
build was installed, no sensor operation was issued, and no release was made
for this refactor; prior physical evidence remains historical.

### Variant checkpoint

The additive variant slice passed 1,125 unit/widget tests, one integration test,
all eight analyzers, formatting, native synthetic checks, and tooling contracts.
Android debug and web builds passed; the existing Cupertino-font warning remains
in the web build. Independent review found a descriptor-only model missing from
Settings/archive labels; the fallback and regression are now fixed, with no
remaining P0/P1/P2 finding in the reviewed slice. All 76 checked local links
resolve. These are local dirty-worktree checks, not clean CI or `make check`.

No physical sensor, country, or additional firmware was tested by this slice.
No phone build was installed or reloaded, no RF command was issued, and no PR,
merge, or release was made. iOS/macOS and signing checks remain outside this
checkpoint. The variant matrix records identification and existing gates, not
new device compatibility.
